variable "lab_id" {
  description = "Identifiant unique du lab"
  type        = string
}

variable "region" {
  description = "Région AWS pour les ressources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block pour le VPC principal"
  type        = string
}

variable "public_cidr" {
  description = "CIDR block pour le subnet public"
  type        = string
}

variable "private_cidr" {
  description = "CIDR block pour le subnet privé"
  type        = string
}
