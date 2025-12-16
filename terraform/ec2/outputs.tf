output "web_public_ip" {
  description = "IP publique du serveur web"
  value       = aws_instance.web.public_ip
}

output "web_private_ip" {
  description = "IP privée du serveur web"
  value       = aws_instance.web.private_ip
}

output "streamer_private_ip" {
  description = "IP privée du serveur streamer"
  value       = aws_instance.streamer.private_ip
}
