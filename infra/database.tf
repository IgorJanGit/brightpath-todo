resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "-_" # RDS rejects / @ " and space; keep it env-file safe too
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20 # Free Tier: 20 GB
  storage_type      = "gp2"
  storage_encrypted = true
  # no max_allocated_storage: storage autoscaling could grow past the free 20 GB

  db_name  = "todo"
  username = "todo_app"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false # private subnets, no public endpoint
  multi_az               = false # Multi-AZ doubles cost; see README

  backup_retention_period      = 1 # max allowed on Free Tier
  auto_minor_version_upgrade   = true
  performance_insights_enabled = false
  monitoring_interval          = 0
  apply_immediately            = true

  # Demo settings so `terraform destroy` leaves nothing behind.
  # For real customer data: final snapshot + deletion protection ON.
  skip_final_snapshot = true
  deletion_protection = false
}

# Everything the app server needs at deploy time, under /<project>/...
# The password is a SecureString (encrypted with the AWS-managed KMS key, free).
locals {
  plain_params = {
    "db/host"            = aws_db_instance.main.address
    "db/port"            = tostring(aws_db_instance.main.port)
    "db/name"            = aws_db_instance.main.db_name
    "db/user"            = aws_db_instance.main.username
    "site_address"       = local.site_address
    "ecr_repository_url" = aws_ecr_repository.app.repository_url
    "log_group"          = aws_cloudwatch_log_group.app.name
  }
}

resource "aws_ssm_parameter" "plain" {
  for_each = local.plain_params
  name     = "/${var.project}/${each.key}"
  type     = "String"
  value    = each.value
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project}/db/password"
  type  = "SecureString"
  value = random_password.db.result
}
