#!/usr/bin/env bash
# Tamaso VM startup script — runs once on first boot.
# Installs Docker, clones deploy repo, runs bootstrap, writes .env.
#
# This is a Terraform template. Variables are injected at plan time.
set -Eeuo pipefail

MARKER="/opt/tamaso/.bootstrap-complete"
if [[ -f "$MARKER" ]]; then
  echo "Bootstrap already completed. Skipping."
  exit 0
fi

echo "==> Installing Docker..."
apt-get update
apt-get install -y ca-certificates curl git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

echo "==> Cloning deploy repo..."
git clone "${deploy_repo_url}" /tmp/vulcan-deploy

echo "==> Running bootstrap..."
/tmp/vulcan-deploy/bootstrap.sh "${customer_id}"

echo "==> Writing /opt/tamaso/.env..."
cat > /opt/tamaso/.env << 'ENVEOF'
GCP_REGION=${gcp_region}
GCP_PROJECT_ID=${gcp_project_id}
AR_REPOSITORY=${ar_repository}
IMAGE_PREFIX=${image_prefix}
GCS_BACKUP_BUCKET=${gcs_backup_bucket}
CUSTOMER_ID=${customer_id}
PLATFORM_VERSION=${platform_version}
APP_HOST=${app_host}
ACME_EMAIL=${acme_email}
DJANGO_DEBUG=false
DJANGO_SECRET_KEY=${django_secret_key}
DJANGO_ALLOWED_HOSTS=${app_host}
DJANGO_CSRF_TRUSTED_ORIGINS=https://${app_host}
DJANGO_TRUST_PROXY_HEADERS=true
DJANGO_NUM_PROXIES=1
VULCAN_VARIANT=${vulcan_variant}
VULCAN_SINGLE_NODE=true
VULCAN_ADMIN_ENABLED=true
ENVEOF
chmod 0600 /opt/tamaso/.env

echo "==> Cleaning up..."
rm -rf /tmp/vulcan-deploy

touch "$MARKER"
echo "==> Bootstrap complete. VM is ready for deployment."
