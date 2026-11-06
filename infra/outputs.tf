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

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
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
  description = "Paste these into GitHub -> Settings -> Secrets and variables -> Actions -> Variables."
  value = {
    AWS_REGION         = var.aws_region
    AWS_ROLE_ARN       = aws_iam_role.github_deploy.arn
    ECR_REPOSITORY_URL = aws_ecr_repository.app.repository_url
    INSTANCE_ID        = aws_instance.app.id
    APP_URL            = local.app_url
  }
}
