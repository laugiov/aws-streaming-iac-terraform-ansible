provider "aws" {
  region = var.region
}

####################### Bucket S3 pour le state #######################
resource "aws_s3_bucket" "tfstate" {
  bucket = "mss-lab-tfstate-${var.lab_id}"

  tags = {
    Name    = "${var.lab_id}-tfstate-bucket"
    lab-id  = var.lab_id
    Purpose = "Terraform state storage"
  }
}

# Versioning pour l'historique des states
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Chiffrement KMS pour une sécurité renforcée
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = "aws/s3"
      sse_algorithm     = "aws:kms"
    }
  }
}

# Blocage de l'accès public
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Access logging pour l'audit
resource "aws_s3_bucket_logging" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  target_bucket = aws_s3_bucket.tfstate.id
  target_prefix = "logs/"
}



####################### Table DynamoDB pour le lock #######################
resource "aws_dynamodb_table" "tflock" {
  name         = "mss-lab-tflock-${var.lab_id}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Chiffrement KMS pour la sécurité
  server_side_encryption {
    enabled = true
  }

  # Point-in-time recovery pour la sauvegarde
  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name    = "${var.lab_id}-tflock-table"
    lab-id  = var.lab_id
    Purpose = "Terraform state locking"
  }
} 