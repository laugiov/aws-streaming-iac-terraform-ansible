output "key_name" {
  description = "Nom de la key pair créée"
  value       = aws_key_pair.main.key_name
}

output "sg_web_id" {
  description = "ID du security group pour le serveur web"
  value       = aws_security_group.web.id
}

output "sg_streamer_id" {
  description = "ID du security group pour le serveur streamer"
  value       = aws_security_group.streamer.id
}
