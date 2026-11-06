#!/usr/bin/env bash
# Provision everything from AWS CloudShell (no local AWS keys needed):
#   bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/infra/cloudshell-apply.sh) <owner/repo> <alert-email>
# Terraform state stays in ~/<repo>/infra (CloudShell home persists); the large
# provider cache goes to /tmp so it doesn't fill the 1 GB home directory.
set -euo pipefail
REPO="${1:?usage: cloudshell-apply.sh <owner/repo> <alert-email>}"
EMAIL="${2:?usage: cloudshell-apply.sh <owner/repo> <alert-email>}"
DIR="$HOME/$(basename "$REPO")"

if ! command -v terraform >/dev/null; then
  sudo yum install -y -q yum-utils
  sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
  sudo yum install -y -q terraform
fi

if [ -d "$DIR/.git" ]; then git -C "$DIR" pull -q; else git clone -q "https://github.com/$REPO.git" "$DIR"; fi
cd "$DIR/infra"
cat > terraform.tfvars <<EOF
github_repo = "$REPO"
alert_email = "$EMAIL"
aws_region  = "${AWS_REGION:-us-east-2}"
EOF
# Optional self-destruct time, e.g. AUTO_DELETE_AT=2027-01-06T13:00:00
if [ -n "${AUTO_DELETE_AT:-}" ]; then echo "auto_delete_at = \"$AUTO_DELETE_AT\"" >> terraform.tfvars; fi

export TF_DATA_DIR=/tmp/tfdata
terraform init -input=false
terraform apply -input=false -auto-approve
terraform output
