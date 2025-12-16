provider "aws" { region = var.region }

#################### 1. AMI Ubuntu 22.04 ####################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

#################### 2. IAM (optionnel) ####################
# création UNIQUEMENT si use_existing_profile = false
resource "aws_iam_role" "r53" {
  count = var.use_existing_profile ? 0 : 1

  name = "${var.lab_id}-r53-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "r53" {
  count  = var.use_existing_profile ? 0 : 1
  name   = "${var.lab_id}-r53-policy"
  role   = aws_iam_role.r53[0].id
  policy = file("${path.module}/route53_policy.json")
}

resource "aws_iam_instance_profile" "r53_profile" {
  count = var.use_existing_profile ? 0 : 1
  name  = "${var.lab_id}-r53-profile"
  role  = aws_iam_role.r53[0].name
}

# profil déjà présent, simplement lu
data "aws_iam_instance_profile" "existing" {
  count = var.use_existing_profile ? 1 : 0
  name  = var.existing_profile_name
}

#################### 3. EC2 Web Frontend ####################
resource "aws_instance" "web" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [var.sg_web_id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  # Configuration de sécurité
  ebs_optimized = true
  monitoring    = true

  # IMDSv2 obligatoire (désactive IMDSv1)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Chiffrement EBS
  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  iam_instance_profile = (
    var.use_existing_profile
    ? data.aws_iam_instance_profile.existing[0].name
    : aws_iam_instance_profile.r53_profile[0].name
  )

  tags = {
    Name   = "${var.lab_id}-web"
    lab-id = var.lab_id
  }
}

#################### 4. EC2 Video Streamer ####################
resource "aws_instance" "streamer" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.sg_streamer_id]
  key_name               = var.key_name
  source_dest_check      = false

  # Configuration de sécurité
  ebs_optimized = true
  monitoring    = true

  # IMDSv2 obligatoire (désactive IMDSv1)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Chiffrement EBS
  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  # IAM role pour l'instance streamer (optionnel mais recommandé)
  iam_instance_profile = (
    var.use_existing_profile
    ? data.aws_iam_instance_profile.existing[0].name
    : aws_iam_instance_profile.r53_profile[0].name
  )

  tags = {
    Name   = "${var.lab_id}-streamer"
    lab-id = var.lab_id
  }
}

#################### 5. Fichiers Ansible ####################
# Chemin absolu vers le dossier ansible/
locals { ansible_dir = abspath("${path.module}/../../ansible") }

resource "local_file" "inventory" {
  filename = "${local.ansible_dir}/inventory.ini"
  content = templatefile("${path.module}/inventory.tpl", {
    web_ip           = aws_instance.web.public_ip,
    streamer_ip_priv = aws_instance.streamer.private_ip
  })
}

resource "local_file" "group_vars" {
  filename = "${local.ansible_dir}/group_vars/all.yml"
  content  = <<EOF
lab_id: "${var.lab_id}"
stream_key: "${var.lab_id}"
rtmp_server: "${aws_instance.web.private_ip}"
domain_fqdn: "${var.domain_fqdn}"
EOF
}
