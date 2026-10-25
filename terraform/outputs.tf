output "web_server_public_ip" {
  description = "Public IP of the web server"
  value       = aws_instance.web.public_ip
}

output "web_server_private_ip" {
  value = aws_instance.web.private_ip
}

output "db_server_private_ip" {
  value = aws_instance.db.private_ip
}
