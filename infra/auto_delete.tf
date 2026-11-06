# Optional self-destruct: one-time EventBridge Scheduler jobs that delete the
# resources that cost money (EC2 instance, RDS database, Elastic IP) at a set
# time, so a forgotten demo can't run up a bill. Everything left behind (VPC,
# security groups, SSM parameters, alarms, budget, IAM roles) is free; remove
# it any time with `terraform destroy`.
#
# Enable with e.g.  auto_delete_at = "2027-01-06T13:00:00"  (America/Los_Angeles)

locals {
  auto_delete = var.auto_delete_at != ""
}

resource "aws_iam_role" "auto_delete" {
  count = local.auto_delete ? 1 : 0
  name  = "${var.project}-auto-delete"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "auto_delete" {
  count = local.auto_delete ? 1 : 0
  name  = "${var.project}-auto-delete"
  role  = aws_iam_role.auto_delete[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ec2:TerminateInstances", Resource = aws_instance.app.arn },
      { Effect = "Allow", Action = "rds:DeleteDBInstance", Resource = aws_db_instance.main.arn },
      { Effect = "Allow", Action = "ec2:ReleaseAddress", Resource = "*" },
    ]
  })
}

resource "aws_scheduler_schedule" "delete_instance" {
  count                        = local.auto_delete ? 1 : 0
  name                         = "${var.project}-auto-delete-ec2"
  schedule_expression          = "at(${var.auto_delete_at})"
  schedule_expression_timezone = var.auto_delete_timezone
  flexible_time_window { mode = "OFF" }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:terminateInstances"
    role_arn = aws_iam_role.auto_delete[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.app.id] })
  }
}

resource "aws_scheduler_schedule" "delete_database" {
  count                        = local.auto_delete ? 1 : 0
  name                         = "${var.project}-auto-delete-rds"
  schedule_expression          = "at(${var.auto_delete_at})"
  schedule_expression_timezone = var.auto_delete_timezone
  flexible_time_window { mode = "OFF" }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:deleteDBInstance"
    role_arn = aws_iam_role.auto_delete[0].arn
    input = jsonencode({
      DbInstanceIdentifier   = aws_db_instance.main.identifier
      SkipFinalSnapshot      = true
      DeleteAutomatedBackups = true
    })
  }
}

# The Elastic IP is released an hour later, once the instance is gone and the
# address is no longer associated (an idle Elastic IP is billed).
resource "aws_scheduler_schedule" "release_ip" {
  count                        = local.auto_delete ? 1 : 0
  name                         = "${var.project}-auto-delete-eip"
  schedule_expression          = "at(${replace(timeadd("${var.auto_delete_at}Z", "1h"), "Z", "")})"
  schedule_expression_timezone = var.auto_delete_timezone
  flexible_time_window { mode = "OFF" }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:releaseAddress"
    role_arn = aws_iam_role.auto_delete[0].arn
    input    = jsonencode({ AllocationId = aws_eip.app.allocation_id })

    retry_policy {
      maximum_retry_attempts       = 10
      maximum_event_age_in_seconds = 21600
    }
  }
}

output "auto_delete" {
  value = local.auto_delete ? "EC2, RDS and Elastic IP will be deleted at ${var.auto_delete_at} ${var.auto_delete_timezone}" : "disabled"
}
