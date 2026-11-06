#!/usr/bin/env bash
# Installs the pull-based deploy timer. Called from EC2 user data on first boot
# (or once via SSM Run Command on an existing instance).
set -euo pipefail
command -v jq >/dev/null || dnf -y -q install jq
install -m 644 /opt/todo/deploy/systemd/todo-autodeploy.service /etc/systemd/system/
install -m 644 /opt/todo/deploy/systemd/todo-autodeploy.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now todo-autodeploy.timer
echo "autodeploy timer installed"
