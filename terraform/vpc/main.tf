provider "aws" { region = var.region }

resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:VPC Flow Logs désactivés : droits IAM insuffisants dans le compte étudiant
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.lab_id}-vpc", lab-id = var.lab_id }
}

# Restreindre le Security Group par défaut
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  # Aucun ingress autorisé
  ingress = []

  # Aucun egress autorisé
  egress = []

  tags = {
    Name   = "${var.lab_id}-default-sg"
    lab-id = var.lab_id
  }
}

resource "aws_subnet" "public" {
  cidr_block              = var.public_cidr
  vpc_id                  = aws_vpc.main.id
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = false
  tags = {
    Name   = "${var.lab_id}-public-subnet"
    lab-id = var.lab_id
  }
}

resource "aws_subnet" "private" {
  cidr_block        = var.private_cidr
  vpc_id            = aws_vpc.main.id
  availability_zone = "${var.region}b"
  tags = {
    Name   = "${var.lab_id}-private-subnet"
    lab-id = var.lab_id
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.lab_id}-igw", lab-id = var.lab_id }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name   = "${var.lab_id}-public-rt"
    lab-id = var.lab_id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}
