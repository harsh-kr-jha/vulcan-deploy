#!/usr/bin/env bash
# One-time VM bootstrap script.
#
# Run this on a fresh Debian 12 GCE instance to prepare it for Tamaso deployments.
# After this completes, the VM is ready to receive deployments via deploy.sh
# (either manually or through the GitHub Action workflow).
#
# Usage:
#   bootstrap.sh <customer_id>
#
# Example:
#   bootstrap.sh MYPOL
#
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <customer_id>" >&2
  exit 2
fi

CUSTOMER_ID="$1"

echo "==> Installing Docker..."
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

echo "==> Creating deployment directories..."
install -d -m 0755 /opt/tamaso
install -d -m 0700 "/var/lib/tamaso/${CUSTOMER_ID}/data"
install -d -m 0700 "/var/lib/tamaso/${CUSTOMER_ID}/backups"
install -d -m 0755 "/var/lib/tamaso/${CUSTOMER_ID}/static"
chown -R 10001:10001 "/var/lib/tamaso/${CUSTOMER_ID}"

echo "==> Installing deployment files..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 0644 "${SCRIPT_DIR}/compose.yaml" /opt/tamaso/compose.yaml
install -m 0644 "${SCRIPT_DIR}/Caddyfile" /opt/tamaso/Caddyfile
install -m 0755 "${SCRIPT_DIR}/deploy.sh" /opt/tamaso/deploy.sh
install -m 0755 "${SCRIPT_DIR}/backup.sh" /opt/tamaso/backup.sh

echo "==> Installing backup timer..."
install -m 0644 "${SCRIPT_DIR}/vulcan-backup.service" /etc/systemd/system/vulcan-backup.service
install -m 0644 "${SCRIPT_DIR}/vulcan-backup.timer" /etc/systemd/system/vulcan-backup.timer
systemctl daemon-reload
systemctl enable --now vulcan-backup.timer

echo ""
echo "Bootstrap complete for customer: ${CUSTOMER_ID}"
echo ""
echo "Next steps:"
echo "  1. Create /opt/tamaso/.env (see .env.example)"
echo "  2. Run: /opt/tamaso/deploy.sh <backend_digest> <frontend_digest> <config_version> <deployment_id>"
echo ""
