variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Short name used for resource names and the SSM parameter prefix (/<project>/...)."
  type        = string
  default     = "todo"
}

variable "github_repo" {
  description = "Public GitHub repository the server clones and deploys from, as \"owner/name\"."
  type        = string
}

variable "alert_email" {
  description = "Email that receives budget and CloudWatch alarm notifications."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is Free Tier eligible for both legacy and post-July-2025 accounts."
  type        = string
  default     = "t3.micro"
}

variable "db_instance_class" {
  description = "RDS instance class (Free Tier: db.t3.micro or db.t4g.micro)."
  type        = string
  default     = "db.t3.micro"
}

variable "enable_https" {
  description = "Serve HTTPS via Caddy + Let's Encrypt on <ip>.sslip.io. Set false for plain HTTP on the Elastic IP."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly AWS Budget; emails at 20% actual and 100% forecasted."
  type        = number
  default     = 5
}

variable "auto_delete_at" {
  description = "Optional local time (YYYY-MM-DDThh:mm:ss) to automatically delete the EC2 instance, RDS database and Elastic IP. Empty = never."
  type        = string
  default     = ""
}

variable "auto_delete_timezone" {
  description = "Time zone for auto_delete_at."
  type        = string
  default     = "America/Los_Angeles"
}
