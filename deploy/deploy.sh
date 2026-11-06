#!/usr/bin/env bash
# Runs ON the EC2 instance, as root, via SSM Run Command (sent by GitHub Actions).
# By the time this runs, the repo in /opt/todo is already checked out at <git-sha>.
#
#   usage: deploy.sh <git-sha>
#
# 1. reads config + DB password from SSM Parameter Store (nothing stored in git)
# 2. logs in to ECR with the instance role (no keys on the box)
# 3. starts the new image and waits for its Docker health check
# 4. rolls back to the previous image if the new one never becomes healthy
set -euo pipefail

SHA="${1:?usage: deploy.sh <git-sha>}"
PREFIX="${PARAM_PREFIX:-/todo}"
APP_DIR=/opt/todo
cd "$APP_DIR"

# --- instance metadata (IMDSv2: token required) ---------------------------
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
imds() { curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
export AWS_REGION; AWS_REGION=$(imds placement/region)
INSTANCE_ID=$(imds instance-id)

# --- config from SSM Parameter Store ---------------------------------------
param() { aws ssm get-parameter --name "$PREFIX/$1" --with-decryption \
            --query Parameter.Value --output text; }
ECR_REPO=$(param ecr_repository_url)
export SITE_ADDRESS; SITE_ADDRESS=$(param site_address)
export LOG_GROUP; LOG_GROUP=$(param log_group)

# Written with umask 077 => readable by root only. Never committed.
( umask 077
  cat > app.env <<EOF
DB_HOST=$(param db/host)
DB_PORT=$(param db/port)
DB_NAME=$(param db/name)
DB_USER=$(param db/user)
DB_PASSWORD=$(param db/password)
DB_SSLMODE=require
APP_VERSION=$SHA
INSTANCE_ID=$INSTANCE_ID
EOF
)

# --- pull and start ---------------------------------------------------------
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_REPO%%/*}" >/dev/null

PREVIOUS_SHA=$(cat .deployed_sha 2>/dev/null || true)
export IMAGE="$ECR_REPO:$SHA"
echo "Deploying $IMAGE (previous: ${PREVIOUS_SHA:-none})"

docker compose pull --quiet
if docker compose up -d --remove-orphans --wait --wait-timeout 120; then
  echo "$SHA" > .deployed_sha
  docker image prune -af --filter "until=72h" >/dev/null || true
  echo "Deploy OK: $SHA is healthy on $INSTANCE_ID"
else
  echo "New version did not become healthy. Last app logs:" >&2
  docker compose logs --tail 40 app >&2 || true
  if [[ -n "$PREVIOUS_SHA" && "$PREVIOUS_SHA" != "$SHA" ]]; then
    echo "Rolling back to $PREVIOUS_SHA" >&2
    sed -i "s/^APP_VERSION=.*/APP_VERSION=$PREVIOUS_SHA/" app.env
    IMAGE="$ECR_REPO:$PREVIOUS_SHA" docker compose up -d --wait --wait-timeout 120 || true
  fi
  exit 1
fi
