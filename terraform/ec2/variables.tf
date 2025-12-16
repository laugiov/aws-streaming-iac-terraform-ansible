variable "lab_id" {
  description = "Identifiant unique du lab"
  type        = string
}

variable "region" {
  description = "Région AWS pour les ressources"
  type        = string
}

variable "key_name" {
  description = "Nom de la key pair pour les instances EC2"
  type        = string
}

variable "public_subnet_id" {
  description = "ID du subnet public pour le serveur web"
  type        = string
}

variable "private_subnet_id" {
  description = "ID du subnet privé pour le serveur streamer"
  type        = string
}

variable "sg_web_id" {
  description = "ID du security group pour le serveur web"
  type        = string
}

variable "sg_streamer_id" {
  description = "ID du security group pour le serveur streamer"
  type        = string
}

variable "domain_fqdn" {
  description = "Nom de domaine FQDN pour le serveur web"
  type        = string
}

variable "use_existing_profile" {
  description = "true pour utiliser un InstanceProfile IAM déjà existant"
  type        = bool
  default     = false
}

variable "existing_profile_name" {
  description = "Nom exact de l'InstanceProfile IAM existant (ex: r53-devops)"
  type        = string
  default     = ""
}
