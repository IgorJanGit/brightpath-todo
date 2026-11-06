# Latest Amazon Linux 2023 (x86_64), looked up from AWS's public SSM parameter.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_eip" "app" {
  domain = "vpc"
  tags   = { Name = "${var.project}-eip" }
}

locals {
  # 203.0.113.10 -> 203-0-113-10.sslip.io, a free DNS name that resolves to the
  # IP itself, so Let's Encrypt can issue a real certificate without buying a domain.
  site_address = var.enable_https ? "${replace(aws_eip.app.public_ip, ".", "-")}.sslip.io" : ":80"
  app_url      = var.enable_https ? "https://${local.site_address}" : "http://${aws_eip.app.public_ip}"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  # no key_name: there is no SSH key at all. Use SSM Session Manager.

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    github_repo = var.github_repo
  })

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers can't reach instance credentials
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 16 # GiB; Free Tier covers 30 GiB of EBS
    encrypted   = true
  }

  credit_specification {
    cpu_credits = "standard" # t3 defaults to "unlimited", which can bill for bursting
  }

  tags = { Name = "${var.project}-app" }

  lifecycle {
    # Don't replace the server every time AWS publishes a new AMI.
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}

# Private container registry for the app image (CI pushes, EC2 pulls).
resource "aws_ecr_repository" "app" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE" # tags are git SHAs; never overwritten
  force_delete         = true        # so `terraform destroy` cleans up fully

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 5 images (stay well under the 500 MB free storage)"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/app"
  retention_in_days = 7
}
