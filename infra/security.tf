# Only the ports the app needs:
#   internet -> EC2 : 80 (HTTP -> HTTPS redirect + Let's Encrypt challenge), 443
#   EC2      -> RDS : 5432, and only from the web server's security group
# No port 22: shell access is through SSM Session Manager.

resource "aws_security_group" "web" {
  name        = "${var.project}-web"
  description = "Public web traffic to the app server"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-web" }
}

resource "aws_vpc_security_group_ingress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP (redirects to HTTPS; ACME challenge)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "web_https" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Outbound: pull images from ECR, talk to SSM/CloudWatch APIs, reach RDS,
# fetch OS updates and Let's Encrypt. (Tightening this needs VPC endpoints,
# which cost money; see README "What I'd change".)
resource "aws_vpc_security_group_egress_rule" "web_all" {
  security_group_id = aws_security_group.web.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = "PostgreSQL, reachable only from the web server"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_web" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from the app server only"
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
