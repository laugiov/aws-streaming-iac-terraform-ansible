output "s3_bucket_name" {
  description = "Nom du bucket S3 pour le state Terraform"
  value       = aws_s3_bucket.tfstate.bucket
}

output "dynamodb_table_name" {
  description = "Nom de la table DynamoDB pour le lock Terraform"
  value       = aws_dynamodb_table.tflock.name
}

output "backend_config" {
  description = "Configuration du backend S3 pour Terraform"
  value = {
    bucket         = aws_s3_bucket.tfstate.bucket
    key            = "state/${var.lab_id}/terraform.tfstate"
    region         = var.region
    dynamodb_table = aws_dynamodb_table.tflock.name
    encrypt        = true
  }
} 