#!/usr/bin/env bash
# Pull-based continuous deployment. Runs on the EC2 instance every minute
# (systemd timer todo-autodeploy.timer). Deploys the newest commit on main
# once GitHub Actions reports its "test" job as successful.
#
# Why pull instead of push: this AWS account's organization SCP denies
# iam:CreateOpenIDConnectProvider, so GitHub Actions can't get AWS creds via
# OIDC, and long-lived access keys in GitHub are what we want to avoid. With
# pull, no AWS credentials ever leave AWS; the instance only needs outbound
# HTTPS to github.com.
#
# Everything is inside main() so bash parses the whole script before running
# it; `git checkout` below may rewrite this very file.
set -euo pipefail

main() {
  cd /opt/todo
  git fetch --quiet origin main
  local target current failed repo runs status conclusion
  target=$(git rev-parse origin/main)
  current=$(cat .deployed_sha 2>/dev/null || echo none)
  failed=$(cat .failed_sha 2>/dev/null || echo none)

  [[ "$target" == "$current" ]] && exit 0   # already live
  [[ "$target" == "$failed" ]] && exit 0    # known-bad commit; wait for a new push

  # Only ship commits whose CI tests passed (public repo, unauthenticated API).
  repo=$(git remote get-url origin | sed -E 's#^https://github.com/##; s#\.git$##')
  runs=$(curl -fsS --max-time 10 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$repo/commits/$target/check-runs?check_name=test") || exit 0
  status=$(jq -r '.check_runs[0].status // "missing"' <<<"$runs")
  conclusion=$(jq -r '.check_runs[0].conclusion // ""' <<<"$runs")

  if [[ "$status" != "completed" ]]; then
    echo "commit ${target:0:7}: CI status '$status', waiting"
    exit 0
  fi
  if [[ "$conclusion" != "success" ]]; then
    echo "commit ${target:0:7}: CI '$conclusion', not deploying"
    echo "$target" > .failed_sha
    exit 0
  fi

  echo "commit ${target:0:7}: CI passed, deploying (current: ${current:0:7})"
  git checkout --quiet --force "$target"
  if bash deploy/deploy.sh "$target"; then
    rm -f .failed_sha
  else
    echo "$target" > .failed_sha
    exit 1
  fi
}

main "$@"
