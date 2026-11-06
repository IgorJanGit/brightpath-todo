#!/usr/bin/env bash
# Runs ON the EC2 instance as root (called by poll.sh, or by hand via SSM).
# By the time this runs, /opt/todo is already checked out at <git-sha>.
#
#   usage: deploy.sh <git-sha>
#
# 1. reads config + DB password from SSM Parameter Store (nothing stored in git)
# 2. builds the image for this commit
# 3. starts it and waits for its Docker health check (/health -> DB reachable)
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
param() { aws ssm get-parameter --region "$AWS_REGION" --name "$PREFIX/$1" --with-decryption \
            --query Parameter.Value --output text; }
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

# --- build and start --------------------------------------------------------
PREVIOUS_SHA=$(cat .deployed_sha 2>/dev/null || true)
export IMAGE="todo-app:$SHA"
echo "Deploying $IMAGE (previous: ${PREVIOUS_SHA:-none})"

docker build --quiet -t "$IMAGE" . >/dev/null
docker compose pull --quiet caddy

if docker compose up -d --remove-orphans --wait --wait-timeout 120; then
  echo "$SHA" > .deployed_sha
  # keep only the current and previous app images (for rollback)
  docker images todo-app --format '{{.Tag}}' | grep -vxE "${SHA}|${PREVIOUS_SHA:-none}" \
    | xargs -r -I{} docker rmi -f "todo-app:{}" >/dev/null || true
  docker image prune -f >/dev/null || true
  echo "Deploy OK: ${SHA:0:7} is healthy on $INSTANCE_ID"
else
  echo "New version did not become healthy. Last app logs:" >&2
  docker compose logs --tail 40 app >&2 || true
  if [[ -n "$PREVIOUS_SHA" && "$PREVIOUS_SHA" != "$SHA" ]]; then
    echo "Rolling back to ${PREVIOUS_SHA:0:7}" >&2
    sed -i "s/^APP_VERSION=.*/APP_VERSION=$PREVIOUS_SHA/" app.env
    IMAGE="todo-app:$PREVIOUS_SHA" docker compose up -d --wait --wait-timeout 120 || true
  fi
  exit 1
fi
