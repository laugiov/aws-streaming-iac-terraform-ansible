#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Full-stack MSS Lab Deployment - 100% auto & idempotent
# ---------------------------------------------------------------------------
set -euo pipefail
export TF_IN_AUTOMATION=1

#############################
# PROJECT PARAMETERS (edit)
#############################
LAB_ID="my-lab-id"                          # Unique lab identifier (e.g.: john-doe-lab)
REGION="us-east-1"                          # AWS Region
DOMAIN_FQDN="my-lab-id.example.com"         # Fully qualified domain name
VPC_CIDR="192.168.0.0/16"                   # VPC CIDR
EXISTING_PROFILE_NAME="r53-devops"          # Existing IAM profile name for Route53

#############################
# 0. General Preparation
#############################
WORKDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MY_IP_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
SSH_KEY_BASE="$HOME/.ssh/myKey-${LAB_ID}"
PUB_KEY="${SSH_KEY_BASE}.pub"
PRIV_KEY="${SSH_KEY_BASE}"

# SSH Agent verification
check_ssh_agent() {
  if ! ssh-add -l | grep -q "${LAB_ID}"; then
    echo "[SSH] Adding SSH key to agent..."
    ssh-add "${PRIV_KEY}"
  fi
  echo "[OK] SSH key loaded in agent"
}

[[ -f "${PRIV_KEY}" ]] || {
  echo "[SSH] Generating SSH key pair ${SSH_KEY_BASE}"
  ssh-keygen -t ed25519 -f "${SSH_KEY_BASE}" -N "" \
             -C "${LAB_ID}@$(hostname)"
}

# Check and configure SSH Agent
check_ssh_agent

mkdir -p "${WORKDIR}/ansible/group_vars"

#############################################################################
# 0.b Complete cleanup of old stack and LAB_ID detection
#############################################################################

delete_keypair() {
  local kp="$1"
  if aws ec2 describe-key-pairs --key-names "$kp" --region "$REGION" >/dev/null 2>&1; then
    echo "[DELETE] Deleting residual Key Pair $kp..."
    aws ec2 delete-key-pair --key-name "$kp" --region "$REGION"
  fi
}

cleanup_lab_vpc() {
  echo "[SEARCH] Cleaning up current lab VPC (${LAB_ID})..."
  vpc_id=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=mss-lab-${LAB_ID}" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
  if [[ "$vpc_id" != "None" && "$vpc_id" != "" ]]; then
    echo "[DELETE] Deleting VPC: $vpc_id (mss-lab-${LAB_ID})"
    # Delete EC2 instances in this VPC
    aws ec2 describe-instances --filters "Name=vpc-id,Values=$vpc_id" "Name=instance-state-name,Values=running,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | \
      tr '\t' '\n' | grep -v '^$' | \
      while read -r instance_id; do
        echo "[DELETE] Terminating EC2 instance: $instance_id"
        aws ec2 terminate-instances --instance-ids "$instance_id" >/dev/null 2>&1 || true
      done
    sleep 10
    # Delete security groups
    aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null | \
      tr '\t' '\n' | grep -v '^$' | \
      while read -r sg_id; do
        echo "[DELETE] Deleting security group: $sg_id"
        aws ec2 delete-security-group --group-id "$sg_id" >/dev/null 2>&1 || true
      done
    # Delete subnets
    aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query 'Subnets[].SubnetId' --output text 2>/dev/null | \
      tr '\t' '\n' | grep -v '^$' | \
      while read -r subnet_id; do
        echo "[DELETE] Deleting subnet: $subnet_id"
        aws ec2 delete-subnet --subnet-id "$subnet_id" >/dev/null 2>&1 || true
      done
    # Delete route tables (except default table)
    aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null | \
      tr '\t' '\n' | grep -v '^$' | \
      while read -r rt_id; do
        echo "[DELETE] Deleting route table: $rt_id"
        aws ec2 delete-route-table --route-table-id "$rt_id" >/dev/null 2>&1 || true
      done
    # Delete internet gateways
    aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null | \
      tr '\t' '\n' | grep -v '^$' | \
      while read -r igw_id; do
        echo "[DELETE] Detaching and deleting internet gateway: $igw_id"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" >/dev/null 2>&1 || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" >/dev/null 2>&1 || true
      done
    # Delete the VPC
    echo "[DELETE] Deleting VPC: $vpc_id"
    aws ec2 delete-vpc --vpc-id "$vpc_id" >/dev/null 2>&1 || true
  else
    echo "No VPC to clean up for this lab."
  fi
}

delete_backend_resources() {
  local lab_id="$1"
  echo "[DELETE] Deleting backend resources for lab_id: ${lab_id}..."

  # Delete DynamoDB table
  if aws dynamodb describe-table --table-name "mss-lab-tflock-${lab_id}" --region "$REGION" >/dev/null 2>&1; then
    echo "[DELETE] Deleting DynamoDB table mss-lab-tflock-${lab_id}..."
    aws dynamodb delete-table --table-name "mss-lab-tflock-${lab_id}" --region "$REGION" >/dev/null 2>&1 || true
  fi

  # Delete S3 bucket (complete emptying before deletion)
  if aws s3api head-bucket --bucket "mss-lab-tfstate-${lab_id}" --region "$REGION" >/dev/null 2>&1; then
    echo "[DELETE] Emptying and deleting S3 bucket mss-lab-tfstate-${lab_id}..."

    # Delete all objects and versions more robustly
    aws s3api list-object-versions --bucket "mss-lab-tfstate-${lab_id}" --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > /tmp/versions.json 2>/dev/null || true
    if [ -s /tmp/versions.json ] && [ "$(jq -r '.Objects | length' /tmp/versions.json 2>/dev/null || echo '0')" -gt 0 ]; then
      echo "[DELETE] Deleting $(jq -r '.Objects | length' /tmp/versions.json) versioned objects"
      aws s3api delete-objects --bucket "mss-lab-tfstate-${lab_id}" --delete file:///tmp/versions.json >/dev/null 2>&1 || true
    fi

    # Delete deletion markers
    aws s3api list-object-versions --bucket "mss-lab-tfstate-${lab_id}" --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' > /tmp/delete-markers.json 2>/dev/null || true
    if [ -s /tmp/delete-markers.json ] && [ "$(jq -r '.Objects | length' /tmp/delete-markers.json 2>/dev/null || echo '0')" -gt 0 ]; then
      echo "[DELETE] Deleting $(jq -r '.Objects | length' /tmp/delete-markers.json) deletion markers"
      aws s3api delete-objects --bucket "mss-lab-tfstate-${lab_id}" --delete file:///tmp/delete-markers.json >/dev/null 2>&1 || true
    fi

    # Verify no objects remain before deleting bucket
    sleep 2
    if aws s3api list-objects-v2 --bucket "mss-lab-tfstate-${lab_id}" --max-items 1 >/dev/null 2>&1; then
      echo "[WARN] Bucket still contains objects, attempting forced deletion"
      aws s3 rb "s3://mss-lab-tfstate-${lab_id}" --force --region "$REGION" >/dev/null 2>&1 || true
    else
      echo "[DELETE] Deleting empty bucket"
      aws s3 rb "s3://mss-lab-tfstate-${lab_id}" --region "$REGION" >/dev/null 2>&1 || true
    fi

    # Cleanup temporary files
    rm -f /tmp/versions.json /tmp/delete-markers.json
  fi
}

# Function to detect old LAB_IDs from existing S3 buckets
detect_old_lab_ids() {
  aws s3api list-buckets --query "Buckets[?contains(Name, 'mss-lab-tfstate-')].Name" --output text 2>/dev/null | \
    tr '\t' '\n' | \
    sed 's/mss-lab-tfstate-//' | \
    grep -v "^${LAB_ID}$" | \
    grep -v "^$" || true
}

# Detect and delete old LAB_IDs
echo "[SEARCH] Detecting old LAB_IDs from S3 buckets..."
OLD_LAB_IDS=$(detect_old_lab_ids)
if [ -n "$OLD_LAB_IDS" ]; then
  echo "[CLEANUP] Deleting detected old LAB_IDs: $OLD_LAB_IDS"
  for old_lab_id in $OLD_LAB_IDS; do
    echo "[DELETE] Deleting resources for old LAB_ID: $old_lab_id"
    delete_backend_resources "$old_lab_id"
    delete_keypair "${old_lab_id}-kp"
  done
fi

# Clean up orphan VPCs
cleanup_lab_vpc

echo "[CLEANUP] Checking lab state for « ${LAB_ID} »..."

# Check if backend already exists
BACKEND_EXISTS=false
if aws s3api head-bucket --bucket "mss-lab-tfstate-${LAB_ID}" --region "$REGION" >/dev/null 2>&1; then
  echo "[OK] Existing S3 backend detected for ${LAB_ID}"
  BACKEND_EXISTS=true
else
  echo "[INFO] No existing S3 backend for ${LAB_ID}"
fi

# If backend exists, try to cleanly destroy with Terraform
if [ "$BACKEND_EXISTS" = true ]; then
  echo "[DELETE] Clean destruction of existing infrastructure..."

  # Delete Terraform modules with existing S3 backend
  for MOD in ec2 security vpc; do
    DIR="${WORKDIR}/terraform/${MOD}"

    # Create temporary backend.tf to enable destruction
    if [ ! -f "${DIR}/backend.tf" ]; then
      cat > "${DIR}/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket         = "mss-lab-tfstate-${LAB_ID}"
    key            = "state/${MOD}/terraform.tfstate"
    region         = "${REGION}"
    dynamodb_table = "mss-lab-tflock-${LAB_ID}"
    encrypt        = true
  }
}
EOF
    fi

    # Initialize and destroy
    echo "[DELETE] Destroying module ${MOD}..."
    terraform -chdir="${DIR}" init -upgrade -input=false >/dev/null 2>&1 || true
    terraform -chdir="${DIR}" destroy -auto-approve -input=false >/dev/null 2>&1 || true

    # Clean up local files
    rm -f "${DIR}/backend.tf"
    rm -f "${DIR}/terraform.tfstate" "${DIR}/terraform.tfstate.backup"
    rm -rf "${DIR}/.terraform" "${DIR}/.terraform.lock.hcl"
  done

  # Now delete the backend
  echo "[DELETE] Deleting backend after infrastructure destruction..."
  delete_backend_resources "$LAB_ID"
  BACKEND_EXISTS=false
else
  echo "[INFO] No existing infrastructure to destroy"
fi

delete_keypair "${LAB_ID}-kp"

echo "✓ Cleanup completed."

#############################
# 0.c S3 + DynamoDB Backend Creation
#############################

# Check if backend already exists
if [ "$BACKEND_EXISTS" = true ]; then
  echo "[OK] Using existing S3 + DynamoDB backend..."
  S3_BUCKET="mss-lab-tfstate-${LAB_ID}"
  DYNAMODB_TABLE="mss-lab-tflock-${LAB_ID}"
  echo "[OK] Existing backend: S3=${S3_BUCKET}, DynamoDB=${DYNAMODB_TABLE}"
else
  echo "[BUILD] Creating S3 + DynamoDB backend for Terraform state..."
  BOOTSTRAP_DIR="${WORKDIR}/terraform/bootstrap"

  # Create terraform.tfvars file for bootstrap
  cat > "${BOOTSTRAP_DIR}/terraform.tfvars" <<EOF
lab_id = "${LAB_ID}"
region = "${REGION}"
EOF

  # Create backend with local state (no S3 backend yet)
  terraform -chdir="${BOOTSTRAP_DIR}" init -upgrade
  terraform -chdir="${BOOTSTRAP_DIR}" apply -auto-approve

  # Retrieve backend information
  S3_BUCKET=$(terraform -chdir="${BOOTSTRAP_DIR}" output -raw s3_bucket_name)
  DYNAMODB_TABLE=$(terraform -chdir="${BOOTSTRAP_DIR}" output -raw dynamodb_table_name)

  echo "[OK] Backend created: S3=${S3_BUCKET}, DynamoDB=${DYNAMODB_TABLE}"
fi

# Function to generate backend.tf files
generate_backend_config() {
  local module_name="$1"
  local module_dir="$2"

  echo "[BUILD] Configuring S3 backend for module ${module_name}..."

  # Generate backend.tf file with correct values
  cat > "${module_dir}/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket         = "${S3_BUCKET}"
    key            = "state/${module_name}/terraform.tfstate"
    region         = "${REGION}"
    dynamodb_table = "${DYNAMODB_TABLE}"
    encrypt        = true
  }
}
EOF
}

#############################
# 1. VPC Module
#############################
VPC_DIR="${WORKDIR}/terraform/vpc"

# Configure S3 backend for VPC
generate_backend_config "vpc" "${VPC_DIR}"

cat > "${VPC_DIR}/terraform.tfvars" <<EOF
lab_id       = "${LAB_ID}"
region       = "${REGION}"
vpc_cidr     = "${VPC_CIDR}"
public_cidr  = "192.168.1.0/24"
private_cidr = "192.168.2.0/24"
EOF

# Check if infrastructure already exists
echo "[SEARCH] Checking VPC infrastructure state..."

# Clean up local files that could cause conflicts
rm -f "${VPC_DIR}/terraform.tfstate" "${VPC_DIR}/terraform.tfstate.backup"
rm -rf "${VPC_DIR}/.terraform" "${VPC_DIR}/.terraform.lock.hcl"

terraform -chdir="${VPC_DIR}" init -upgrade >/dev/null 2>&1

# Try to retrieve existing outputs
echo "[BUILD] Creating VPC infrastructure..."
terraform -chdir="${VPC_DIR}" apply -auto-approve
VPC_ID=$(terraform -chdir="${VPC_DIR}" output -raw vpc_id)
PUB_SUB=$(terraform -chdir="${VPC_DIR}" output -raw public_subnet_id)
PRIV_SUB=$(terraform -chdir="${VPC_DIR}" output -raw private_subnet_id)
echo "[INFO] VPC_ID: ${VPC_ID}"
echo "[INFO] Public Subnet: ${PUB_SUB}"
echo "[INFO] Private Subnet: ${PRIV_SUB}"

#############################
# 2. Security Module
#############################
SEC_DIR="${WORKDIR}/terraform/security"

# Configure S3 backend for Security
generate_backend_config "security" "${SEC_DIR}"

cat > "${SEC_DIR}/terraform.tfvars" <<EOF
lab_id          = "${LAB_ID}"
region          = "${REGION}"
vpc_id          = "${VPC_ID}"
my_ip_cidr      = "${MY_IP_CIDR}"
public_key_path = "${PUB_KEY}"
EOF

# Check if infrastructure already exists
echo "[SEARCH] Checking Security infrastructure state..."

# Clean up local files that could cause conflicts
rm -f "${SEC_DIR}/terraform.tfstate" "${SEC_DIR}/terraform.tfstate.backup"
rm -rf "${SEC_DIR}/.terraform" "${SEC_DIR}/.terraform.lock.hcl"

terraform -chdir="${SEC_DIR}" init -upgrade >/dev/null 2>&1

# Try to retrieve existing outputs
echo "[BUILD] Creating Security infrastructure..."
terraform -chdir="${SEC_DIR}" apply -auto-approve
KEY_NAME=$(terraform -chdir="${SEC_DIR}" output -raw key_name)
SG_WEB=$(terraform -chdir="${SEC_DIR}" output -raw sg_web_id)
SG_STREAMER=$(terraform -chdir="${SEC_DIR}" output -raw sg_streamer_id)
echo "[INFO] Key Name: ${KEY_NAME}"
echo "[INFO] SG Web: ${SG_WEB}"
echo "[INFO] SG Streamer: ${SG_STREAMER}"

#############################
# 3. EC2 Module
#############################
EC2_DIR="${WORKDIR}/terraform/ec2"

# Configure S3 backend for EC2
generate_backend_config "ec2" "${EC2_DIR}"

cat > "${EC2_DIR}/terraform.tfvars" <<EOF
lab_id            = "${LAB_ID}"
region            = "${REGION}"
key_name          = "${KEY_NAME}"
public_subnet_id  = "${PUB_SUB}"
private_subnet_id = "${PRIV_SUB}"
sg_web_id         = "${SG_WEB}"
sg_streamer_id    = "${SG_STREAMER}"
domain_fqdn       = "${DOMAIN_FQDN}"
use_existing_profile  = true
existing_profile_name = "${EXISTING_PROFILE_NAME}"
EOF

# Check if infrastructure already exists
echo "[SEARCH] Checking EC2 infrastructure state..."

# Clean up local files that could cause conflicts
rm -f "${EC2_DIR}/terraform.tfstate" "${EC2_DIR}/terraform.tfstate.backup"
rm -rf "${EC2_DIR}/.terraform" "${EC2_DIR}/.terraform.lock.hcl"

terraform -chdir="${EC2_DIR}" init -upgrade >/dev/null 2>&1

# Try to retrieve existing outputs
echo "[BUILD] Creating EC2 infrastructure..."
terraform -chdir="${EC2_DIR}" apply -auto-approve
WEB_IP=$(terraform -chdir="${EC2_DIR}" output -raw web_public_ip)
WEB_PRIV=$(terraform -chdir="${EC2_DIR}" output -raw web_private_ip)
STREAMER_PRIV=$(terraform -chdir="${EC2_DIR}" output -raw streamer_private_ip)
echo "[INFO] Web Public IP: ${WEB_IP}"
echo "[INFO] Web Private IP: ${WEB_PRIV}"
echo "[INFO] Streamer Private IP: ${STREAMER_PRIV}"

echo -e "\n[OK] Infrastructure ready."

# ------------------- Dynamic Ansible group_vars ------------------------
cat > "${WORKDIR}/ansible/group_vars/all.yml" <<EOF
lab_id:       "${LAB_ID}"
stream_key:   "${LAB_ID}"
rtmp_server:  "${WEB_PRIV}"
domain_fqdn:  "${DOMAIN_FQDN}"
EOF
echo "[INFO] group_vars/all.yml generated (rtmp -> ${WEB_PRIV})"

# ------------------- DNS Route 53 (UPSERT) --------------------------------
cat > dns-upsert-${LAB_ID}.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${DOMAIN_FQDN}",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{ "Value": "${WEB_IP}" }]
    }
  }]
}
EOF

# IMPORTANT: Replace ZXXXXXXXXXXXXX with your Route53 Hosted Zone ID
HOSTED_ZONE_ID="ZXXXXXXXXXXXXX"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://dns-upsert-${LAB_ID}.json"

# Cleanup DNS temporary file
rm -f "dns-upsert-${LAB_ID}.json"

# ------------------- Idempotent SSH config block ---------------------------

SSH_CFG="$HOME/.ssh/config"
CFG_BEGIN="# >>> MSS-${LAB_ID}-START"
CFG_END="# <<< MSS-${LAB_ID}-END"

cat > /tmp/mss_ssh_block <<EOF
${CFG_BEGIN}
Host mss-web-${LAB_ID}
  HostName ${WEB_IP}
  User ubuntu
  IdentityFile ${SSH_KEY_BASE}
  ForwardAgent yes
  StrictHostKeyChecking accept-new

Host mss-streamer-${LAB_ID}
  HostName ${STREAMER_PRIV}
  User ubuntu
  IdentityFile ${SSH_KEY_BASE}
  ProxyJump mss-web-${LAB_ID}
  ForwardAgent yes
  StrictHostKeyChecking accept-new
${CFG_END}
EOF

touch "${SSH_CFG}"
sed -i "/${CFG_BEGIN}/,/${CFG_END}/d" "${SSH_CFG}"
cat /tmp/mss_ssh_block >> "${SSH_CFG}"
chmod 600 "${SSH_CFG}"
echo "[SSH] ~/.ssh/config updated"

# Cleanup SSH temporary file
rm -f /tmp/mss_ssh_block

echo "[WAIT] Waiting for SSH to be available on Web VM (${WEB_IP})..."
for ((i=1; i<=10; i++)); do
  if ssh -o BatchMode=yes -o ConnectTimeout=3 ubuntu@"${WEB_IP}" exit 0 2>/dev/null; then
    echo "[OK] SSH ready after $((i*5)) s."
    break
  fi
  printf "\r... %02ds" $((i*5))
  sleep 5
done
echo

# -------------------------------------------------------------------
# 4. Software Configuration (Ansible)
# -------------------------------------------------------------------

ssh-add -D                              # completely empty the agent
ssh-add "${PRIV_KEY}"                   # load only the lab key

ANSIBLE_DIR="${WORKDIR}/ansible"

echo "[RUN] Software configuration (Ansible)..."
ansible-playbook \
  -i "${ANSIBLE_DIR}/inventory.ini" \
  "${ANSIBLE_DIR}/web_frontend.yml" \
  "${ANSIBLE_DIR}/video_streamer.yml"

echo "[DONE] Deployment complete - everything is ready!"
