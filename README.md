# AWS Video Streaming Platform - 100% Automated Deployment

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.7-purple.svg)
![Ansible](https://img.shields.io/badge/Ansible-%3E%3D2.15-red.svg)
![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20VPC%20%7C%20Route53-orange.svg)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20LTS-E95420.svg)

## Table of Contents
1. [Project Objective](#objective)
2. [Prerequisites](#prerequisites)
3. [Repository Structure](#structure)
4. [Deployment: `run-all.sh` script](#run-all)
5. [Terraform Infrastructure](#infra)
6. [Ansible Configuration](#ansible)
7. [Secure SSH Access via Bastion](#ssh)
8. [Tests & Idempotence](#tests)
9. [Code Quality & Security](#quality)
10. [Makefile - Quick Commands](#makefile)
11. [Future Improvements](#todo)
12. [Author](#author)

---

<a name="objective"></a>
## 1 | Project Objective

Deploy **in less than 10 minutes** a mini video streaming platform that demonstrates the
**RTMP -> HLS / HTTPS** pipeline:

```
  (private)                               (public)
+---------------+  RTMP  +-------------+  HLS/HTTPS  +---------+
| Video Streamer| ------> |  Web NGINX  | ------------>| Viewer  |
| FFmpeg loop   |        | NGINX-RTMP  |             | Browser |
+---------------+        +-------------+             +---------+
     subnet 2                subnet 1                  internet
```

Everything is described **as code** (IaC):
* **Terraform** builds VPC / SG / EC2 / DNS.
* **Ansible** installs FFmpeg, NGINX-RTMP and Let's Encrypt.
* The **`run-all.sh`** script chains both tools, manages SSH
  *proxy-jump*, waits for port availability and pushes the configuration.

---

<a name="prerequisites"></a>
## 2 | Prerequisites

| Workstation    | Min Version  | Notes |
| -------------- | ------------ | ----- |
| Terraform      | >= 1.7       | tested with 1.8 |
| Ansible Core   | >= 2.15      | `amazon.aws` & `community.aws` collections |
| AWS CLI v2     | latest       | SSO authentication |
| OpenSSH        | >= 8.4       | for `ProxyJump` and SSH Agent Forwarding |
| GNU bash       | >= 5         | to run `run-all.sh` |
| SSH Agent      | active       | for SSH Agent Forwarding (no key copying) |

Minimum IAM level:
* SSO Permission-set (EC2/VPC/Route53/ACM...)
* Instance profile with `route53:ChangeResourceRecordSets` action.

To start an AWS session:

```sh
aws configure sso --use-device-code
```

**SSH Agent Configuration (required):**
```sh
# Start the SSH agent
eval "$(ssh-agent -s)"

# Add key to the agent (automatic via run-all.sh)
ssh-add ~/.ssh/myKey-<LAB_ID>
```

---

<a name="structure"></a>
## 3 | Repository Structure

```text
.
├── run-all.sh                          # one-shot pipeline
├── Makefile                            # quick commands and maintenance
├── terraform/.tflint.hcl               # TFLint configuration
├── ansible/
│   ├── ansible.cfg                     # Ansible configuration
│   ├── inventory.ini                   # dynamic inventory (generated)
│   ├── group_vars/all.yml              # global variables (generated)
│   ├── web_frontend.yml                # web server playbook
│   ├── video_streamer.yml              # streamer playbook
│   └── roles/
│       ├── web_frontend/               # NGINX-RTMP + TLS
│       └── video_streamer/             # FFmpeg loop -> RTMP
└── terraform/
    ├── bootstrap/  # S3 + DynamoDB Backend
    ├── vpc/        # VPC module
    ├── security/   # SG + KeyPair
    └── ec2/        # EC2 + inventory generation
```

---

<a name="run-all"></a>
## 4 | Automatic Deployment - `run-all.sh`

### Before running `run-all.sh` - Installation & initialization checklist

```bash
ansible-galaxy collection install amazon.aws community.aws
aws configure sso --use-device-code  # enter URL & account name
aws sso login --profile YourProfile  # for each new session
export AWS_PROFILE=YourProfile       # (or add to ~/.bashrc)
```

```bash
git clone https://github.com/<YOUR_USERNAME>/aws-streaming-iac-terraform-ansible && cd aws-streaming-iac-terraform-ansible
nano run-all.sh   # edit LAB_ID, REGION, DOMAIN_FQDN, VPC_CIDR, EXISTING_PROFILE_NAME
./run-all.sh
```

**Alternative launch with Makefile:**
```bash
make help        # see all available commands, also edit LAB_ID, etc.
make deploy      # full deployment
```

### Internal Pipeline

| Step | Details | Duration |
| ---- | ------- | -------- |
| 0 | SSH key pair `~/.ssh/myKey-$LAB_ID` | instant |
| 1 | Terraform **backend** | ~60 s |
| 2 | Terraform **vpc** | ~90 s |
| 3 | Terraform **security** | ~90 s |
| 4 | Terraform **ec2** | ~180 s |
| 5 | DNS Route53 UPSERT | <5 s |
| 6 | Patch `~/.ssh/config` | instant |
| 7 | **wait-SSH** loop (max 150 s) | adaptive |
| 8 | Ansible: `web_frontend` -> `video_streamer` | ~90 s |

Total: **~10 min** max on a lightly loaded region.

---

<a name="infra"></a>
## 5 | Terraform Infrastructure

### 5.1 S3 + DynamoDB Lock Backend

The project uses a **secure S3 backend** with DynamoDB locking for Terraform state:

| Resource | Name | Function |
|----------|------|----------|
| **S3 Bucket** | `mss-lab-tfstate-<LAB_ID>` | Versioned and encrypted state storage |
| **DynamoDB Table** | `mss-lab-tflock-<LAB_ID>` | Concurrent operation locking |

**Benefits:**
- **Automatic locking**: Prevents concurrent corruption
- **Automatic backup**: S3 versioning + SSE-S3 encryption
- **Team collaboration**: Secure state sharing
- **Traceability**: Complete modification history

**Backend verification:**
```bash
# Check S3 bucket
aws s3 ls s3://mss-lab-tfstate-<LAB_ID>/

# Check DynamoDB table
aws dynamodb describe-table --table-name mss-lab-tflock-<LAB_ID>
```

### 5.2 Modular Terraform Architecture

The project follows a **modular architecture** with independent and reusable Terraform modules:

```
terraform/
├── bootstrap/    # S3 + DynamoDB Backend (remote state)
├── vpc/          # Network: VPC, subnets, route tables
├── security/     # Security: Security Groups, Key Pairs
└── ec2/          # Compute: EC2 instances, IAM roles
```

#### **Bootstrap Module** - Foundations
**Role**: Create base infrastructure for Terraform state
- **S3 Bucket**: Versioned and encrypted state storage
- **DynamoDB Table**: Concurrent operation locking
- **Security**: KMS encryption, access logging, public access blocking

#### **VPC Module** - Network
**Role**: Define isolated network architecture
- **VPC**: CIDR `192.168.0.0/16` (configurable)
- **Subnets**: Public (`192.168.1.0/24`) and Private (`192.168.2.0/24`)
- **Internet Gateway**: Internet connection for public subnet
- **Route Tables**: Automatic and controlled routing
- **Default Security Group**: Blocked (zero traffic allowed)

#### **Security Module** - Security
**Role**: Define security rules and authentication
- **Web Security Group**: HTTP(80), HTTPS(443), SSH from your IP
- **Streamer Security Group**: SSH from Web, outbound RTMP to Web
- **Key Pair**: SSH authentication for instances
- **Restricted Egress**: Least privilege principle

#### **EC2 Module** - Instances
**Role**: Deploy instances
- **Web Instance**: `t3.small` in public subnet (bastion + web server)
- **Streamer Instance**: `t3.micro` in private subnet (video generation)
- **IAM Roles**: Route53 permissions for Let's Encrypt
- **Secure Metadata**: IMDSv2 mandatory

#### **Module Integration**
Modules communicate via **outputs** and **data sources**:
```hcl
# VPC Module -> Security Module
vpc_id = module.vpc.vpc_id

# Security Module -> EC2 Module
key_name = module.security.key_name
sg_web_id = module.security.sg_web_id

# EC2 Module -> Ansible
web_public_ip = module.ec2.web_public_ip
streamer_private_ip = module.ec2.streamer_private_ip
```

#### **Architecture Benefits**
- **Reusability**: Independent, reusable modules
- **Security**: Separation of responsibilities
- **Scalability**: Easy to add new modules
- **Testability**: Unit tests per module
- **Collaboration**: Team work on different modules

---

<a name="ansible"></a>
## 6 | Ansible Configuration

### 6.1 Role Architecture

The project uses a **modular Ansible architecture** with specialized roles:

```
ansible/
├── group_vars/all.yml           # Global variables (generated by Terraform)
├── web_frontend.yml             # Main web playbook
├── video_streamer.yml           # Main streamer playbook
└── roles/
    ├── web_frontend/            # NGINX + RTMP + TLS role
    │   ├── tasks/main.yml       # Installation and configuration
    │   ├── templates/           # NGINX config + index.html
    │   └── handlers/main.yml    # Reload NGINX
    └── video_streamer/          # FFmpeg + streaming role
        ├── tasks/main.yml       # FFmpeg + video + service
        └── templates/           # Systemd service
```

### 6.2 Dynamic Inventory

The inventory is **automatically generated** by Terraform / run-all.sh with dynamic IPs:

```ini
[web]
<WEB_PUBLIC_IP> ansible_user=ubuntu ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

[streamer]
<STREAMER_PRIVATE_IP> ansible_user=ubuntu ansible_ssh_common_args='-o ProxyJump=ubuntu@<WEB_PUBLIC_IP> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```
Future improvement: use the *Dynamic Host Inventory plugin*.

**Global variables** (`group_vars/all.yml`):
```yaml
lab_id: "<LAB_ID>"
stream_key: "<LAB_ID>"
rtmp_server: "<WEB_PRIVATE_IP>"
domain_fqdn: "<LAB_ID>.<YOUR_DOMAIN>"
```

> **SSH Agent Forwarding**: Private keys are never copied to servers.
> Ansible uses the local SSH agent for authentication via `ForwardAgent=yes`.

### 6.3 **web_frontend** Role - Web & RTMP Server

**Objective**: Deploy an NGINX server with RTMP module and TLS certificate

#### **Package Installation**
```bash
nginx + libnginx-mod-rtmp + python3-certbot-dns-route53
```

#### **2-Phase Configuration**
1. **HTTP Phase**: Basic NGINX configuration to obtain certificate
2. **HTTPS Phase**: TLS activation with 80 -> 443 redirect

#### **Let's Encrypt Certificate**
- **Method**: DNS-01 Challenge (Route53)
- **Automation**: Automatic renewal
- **Security**: No HTTP exposure during validation

#### **RTMP Configuration**
```nginx
rtmp {
    server {
        listen 1935;
        application live {
            live on;
            hls on;
            hls_path /var/www/hls;
            hls_fragment 3;
            hls_playlist_length 60;
        }
    }
}
```

### 6.4 **video_streamer** Role - Stream Generator

**Objective**: Deploy FFmpeg to generate a continuous RTMP stream

#### **FFmpeg Installation**
- **Source**: Static version `ffmpeg-release-amd64-static`
- **Method**: Local download then copy (network/security optimization)
- **Location**: `/usr/local/bin/ffmpeg`
- **Management**: `force: yes` for automatic FFmpeg updates

#### **Demo Video**
- **Source**: Big Buck Bunny (open license video)
- **Format**: High quality MP4


#### **Systemd Service**
```ini
[Unit]
Description=FFmpeg RTMP Streamer
After=network.target

[Service]
Type=simple
User=ubuntu
ExecStart=/usr/local/bin/ffmpeg -re -i /home/ubuntu/video.mp4 -c copy -f flv rtmp://<WEB_PRIVATE_IP>:1935/live/<LAB_ID>
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 6.5 Web Frontend - HLS Player

The frontend includes a modern HTML5 player with HLS.js:

**Key Features:**
- **HTML5 + HLS Player**: Plyr 3 + hls.js
- **Responsive Design**: Dark background, rounded card
- **Network Logs Panel**: Live statistics and HLS events
- **Customization**: Colors, size, configuration via CSS

**Access**: https://<LAB_ID>.<YOUR_DOMAIN>

### 6.6 Data Flow

```
┌─────────────────┐    RTMP     ┌─────────────────┐    HLS      ┌─────────────────┐
│ Video Streamer  │ -----------> │   Web Server    │ -----------> │    Browser      │
│ FFmpeg Loop     │  1935/tcp   │ NGINX + RTMP    │   HTTPS     │ HLS.js Player   │
│ Big Buck Bunny  │             │ Let's Encrypt   │             │                 │
└─────────────────┘             └─────────────────┘             └─────────────────┘
     Private Subnet                  Public Subnet                    Internet
```

---

<a name="ssh"></a>
## 7 | Secure SSH Access via Bastion

The run-all.sh script automatically configures secure SSH access via Bastion from the web frontend to the video streamer:
```sshconfig
# >>> MSS-<LAB_ID>-START
Host mss-web-<LAB_ID>
  HostName <web_public_ip>
  User ubuntu
  IdentityFile ~/.ssh/myKey-<LAB_ID>
  ForwardAgent yes

Host mss-streamer-<LAB_ID>
  HostName <streamer_private_ip>
  User ubuntu
  IdentityFile ~/.ssh/myKey-<LAB_ID>
  ProxyJump mss-web-<LAB_ID>
  ForwardAgent yes
# <<< MSS-<LAB_ID>-END
```
**Benefits**:

* Simplifies SSH commands
* Avoids handling dynamic IPs
* Ensures secure connection to private subnet via bastion
* Aligns SSH and Ansible on the same configuration

> **SSH Agent Forwarding**: `ForwardAgent yes` allows streamer access
> without copying private keys to servers.

---

<a name="tests"></a>
## 8 | Tests & Idempotence

**Site URL**: https://<LAB_ID>.<YOUR_DOMAIN>

* **HLS Manifest**

  ```bash
  curl -f https://<LAB_ID>.<YOUR_DOMAIN>/hls/<LAB_ID>.m3u8 | head
  ```

* **Re-playbook**:

  ```bash
  ansible-playbook ansible/web_frontend.yml   # changed=0
  ansible-playbook ansible/video_streamer.yml # changed=0
  ```
---

<a name="quality"></a>
## 9 | Code Quality & Security

### 9.1 Terraform Quality Controls

**TFLint** - Terraform static linting:
```bash
# Local installation
apt install tflint  # ubuntu

# Execution
cd terraform
tflint --init
tflint --recursive
```

**Configuration**: `terraform/.tflint.hcl` with AWS plugin to detect:
- Resource naming
- Variable types
- Provider versions
- AWS policies (IAM, Security Groups, etc.)

### 9.2 Checkov Security Analysis

**Checkov** - "Policies as Code":
```bash
# Local installation -> via python
pip install checkov

# Execution
checkov -d terraform/ -o cli
```

**Security Results**:
- **Before**: 30 checks PASSED, 29 checks FAILED (51% compliance)
- **After**: 51 checks PASSED, 8 checks FAILED (86% compliance)

**Main improvements applied**:
- **EBS Encryption**: Volumes encrypted by default
- **IMDSv2**: Instance Metadata Service v2 mandatory (SSRF protection)
- **Security Groups**: Restrictive rules with descriptions
- **Egress Rules**: Minimal outbound traffic (least privilege principle)
- **Default Security Group**: Blocked (no traffic allowed)
- **Public Subnet**: No automatic public IP
- **Secure S3**: KMS encryption, versioning, access logging, public access blocking
- **DynamoDB**: Point-in-time recovery, auto-scaling

**Remaining issues** (acceptable for a lab):
- Web instance with public IP (normal for a web server)
- Port 80 open on 0.0.0.0/0 (standard for HTTP)
- No VPC Flow Logs (insufficient IAM rights in student account)

### 9.3 Local Tests

```bash
# Terraform formatting check
make fmt

# Linting and security analysis
make lint
make security
```

---

<a name="makefile"></a>
## 10 | Makefile - Quick Commands

The project includes a **Makefile** with essential commands.

### 10.1 Available Commands

```bash
# Help and deployment
make help                   # Display help and configuration
make deploy                 # Full deployment (run-all.sh)
make ansible-web            # Ansible deployment on web frontend
make ansible-streamer       # Ansible deployment on video streamer backend

# Key and access management
make ssh-keys               # Generate SSH keys
make ssh-web                # SSH connection to web server
make ssh-streamer           # SSH connection to streamer server

# Verification and maintenance
make status                 # Display service status
make logs                   # Display service logs
make clean                  # Clean temporary files
make fmt                    # Format Terraform code
make lint                   # Run TFLint
make security               # Run Checkov
```

### 10.2 Recommended Workflow

```bash
# Typical complete workflow
make help                   # See help and configuration
make deploy                 # Full deployment
make status                 # Check services
# If needed for troubleshooting:
make ssh-web                # SSH to web server
make ssh-streamer           # SSH to streamer server
```

---

<a name="todo"></a>
## 11 | Future Improvements

* Periodic Let's Encrypt certificate renewal
* Ansible dynamic inventory (amazon.aws.ec2 plugin)
* Secrets stored in **Ansible Vault** + KMS (AWS)
* WAF + Shield (AWS) on a future HTTP(S) **Load Balancer**
* NGINX autoscaling group + round-robin **Load Balancer**
* IDS via **Traffic Mirror**
* Observability: CloudWatch Logs -> Grafana Cloud
* CI/CD GitHub Actions (terraform-fmt, tflint, ansible-lint, Molecule)

---

<a name="author"></a>
## 12 | Author

**Laurent Giovannoni**

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
