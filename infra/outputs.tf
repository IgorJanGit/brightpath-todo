output "app_url" {
  description = "Public link to the app."
  value       = local.app_url
}

output "health_url" {
  value = "${local.app_url}/health"
}

output "elastic_ip" {
  value = aws_eip.app.public_ip
}

output "instance_id" {
  value = aws_instance.app.id
}

output "rds_endpoint" {
  description = "Private endpoint; only reachable from inside the VPC."
  value       = aws_db_instance.main.address
}

output "shell_command" {
  description = "Open a shell on the instance without SSH."
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}

output "github_variables" {
  description = "Paste into GitHub -> Settings -> Secrets and variables -> Actions -> Variables."
  value = {
    APP_URL = local.app_url
  }
}
