variable "lab_id" {
  description = "Identifiant unique du lab"
  type        = string
}

variable "region" {
  description = "Région AWS pour les ressources"
  type        = string
}

variable "vpc_id" {
  description = "ID du VPC où créer les security groups"
  type        = string
}

variable "my_ip_cidr" {
  description = "CIDR de l'IP publique de l'utilisateur (format: x.x.x.x/32)"
  type        = string
}

variable "public_key_path" {
  description = "Chemin vers la clé publique SSH"
  type        = string
}
