provider "aws" { region = var.region }

####################### Key Pair #######################
resource "aws_key_pair" "main" {
  key_name   = "${var.lab_id}-kp"
  public_key = file(var.public_key_path)
  tags       = { lab-id = var.lab_id }
}

####################### SG Web ##########################
resource "aws_security_group" "web" {
  name        = "${var.lab_id}-sg-web"
  description = "HTTP/HTTPS, RTMP, SSH bastion"
  vpc_id      = var.vpc_id

  lifecycle {
    ignore_changes = [description]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
    description = "SSH access from my IP"
  }

  # 80 / 443 : HTTP / HTTPS traffic
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access from internet"
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access from internet"
  }

  # 1935 : RTMP incoming from private subnet
  ingress {
    from_port   = 1935
    to_port     = 1935
    protocol    = "tcp"
    cidr_blocks = ["192.168.0.0/16"]
    description = "RTMP from private subnet"
  }

  # Restricted egress : only necessary ports
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outgoing HTTP for package updates"
  }
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outgoing HTTPS for updates and Lets Encrypt"
  }
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "DNS resolution"
  }

  tags = { lab-id = var.lab_id }
}

####################### SG Streamer #####################
resource "aws_security_group" "streamer" {
  name        = "${var.lab_id}-sg-streamer"
  description = "SSH from bastion, RTMP outgoing to Web"
  vpc_id      = var.vpc_id

  lifecycle {
    ignore_changes = [description]
  }

  # SSH allowed from Web SG (bastion)
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
    description     = "SSH from web bastion"
  }

  # RTMP outgoing to Web SG
  egress {
    from_port       = 1935
    to_port         = 1935
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
    description     = "RTMP to web server"
  }
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "DNS resolution"
  }

  tags = { lab-id = var.lab_id }
}

# Separate SSH egress rule to avoid circular dependencies
resource "aws_security_group_rule" "web_to_streamer_ssh" {
  type                     = "egress"
  description              = "Outgoing SSH to streamer"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.web.id
  source_security_group_id = aws_security_group.streamer.id
}


