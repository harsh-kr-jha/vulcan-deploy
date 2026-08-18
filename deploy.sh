#!/usr/bin/env bash
# Tamaso customer GCE deployment script.
#
# Deploys a specific artifact digest pair to the customer VM. Performs backup,
# migration, health check, and automatic rollback on failure.
#
# Usage:
#   deploy.sh <backend_digest> <frontend_digest> <config_version> <deployment_id>
#
# Arguments:
#   backend_digest   - sha256:<64-hex-chars> digest for the backend image
#   frontend_digest  - sha256:<64-hex-chars> digest for the frontend image
#   config_version   - Client configuration version (e.g. MYPOL-C01)
#   deployment_id    - Unique deployment identifier (e.g. mypol-prod-01)
#
# Environment (sourced from /opt/tamaso/.env):
#   GCP_REGION, GCP_PROJECT_ID, AR_REPOSITORY, IMAGE_PREFIX, CUSTOMER_ID,
#   PLATFORM_VERSION, APP_HOST
#
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <backend_digest> <frontend_digest> <config_version> <deployment_id>" >&2
  exit 2
fi

backend_digest="$1"
frontend_digest="$2"
config_version="$3"
deployment_id="$4"

# Validate digest format
for digest in "$backend_digest" "$frontend_digest"; do
  if [[ ! "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo "Invalid digest format: $digest (expected sha256:<64-hex-chars>)" >&2
    exit 2
  fi
done

cd /opt/tamaso

# Prevent concurrent deployments
exec 9>/run/tamaso-deploy.lock
flock -n 9 || { echo "Another deployment is running." >&2; exit 1; }

# Load environment
set -a
# shellcheck disable=SC1091
source .env
set +a

: "${GCP_REGION:?GCP_REGION is required}"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
: "${AR_REPOSITORY:?AR_REPOSITORY is required}"
: "${IMAGE_PREFIX:?IMAGE_PREFIX is required}"
: "${CUSTOMER_ID:?CUSTOMER_ID is required}"

# --- Pre-deployment backup (MUST succeed) ---
./backup.sh || {
  echo "Pre-deployment backup failed. Refusing to proceed." >&2
  exit 1
}

# --- Authenticate to Artifact Registry ---
registry="${GCP_REGION}-docker.pkg.dev"
access_token="$(
  curl --fail --silent --show-error \
    -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
)"
printf '%s' "$access_token" | docker login -u oauth2accesstoken --password-stdin "$registry"

# --- Compute image references ---
backend_image="${registry}/${GCP_PROJECT_ID}/${AR_REPOSITORY}/${IMAGE_PREFIX}-backend@${backend_digest}"
frontend_image="${registry}/${GCP_PROJECT_ID}/${AR_REPOSITORY}/${IMAGE_PREFIX}-frontend@${frontend_digest}"

# --- Save rollback state ---
cp .env .env.rollback

# --- Update environment with new image references ---
sed -i '/^BACKEND_IMAGE=/d' .env
sed -i '/^FRONTEND_IMAGE=/d' .env
sed -i '/^CONFIG_VERSION=/d' .env
echo "BACKEND_IMAGE=${backend_image}" >> .env
echo "FRONTEND_IMAGE=${frontend_image}" >> .env
echo "CONFIG_VERSION=${config_version}" >> .env

# Re-source with new values
set -a; source .env; set +a
export BACKEND_IMAGE FRONTEND_IMAGE CONFIG_VERSION

# --- Rollback function ---
rollback() {
  echo "DEPLOYMENT FAILED — rolling back to previous state..." >&2
  cp .env.rollback .env
  set -a; source .env; set +a
  docker compose --env-file .env up -d --remove-orphans --wait --wait-timeout 180 || true

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"timestamp":"%s","customer_id":"%s","deployment_id":"%s","config_version":"%s","backend_digest":"%s","frontend_digest":"%s","platform_version":"%s","status":"ROLLBACK"}\n' \
    "$ts" "$CUSTOMER_ID" "$deployment_id" "$config_version" "$backend_digest" "$frontend_digest" "${PLATFORM_VERSION:-unknown}" \
    >> /opt/tamaso/deployments.json

  echo "Rollback complete. Previous deployment restored." >&2
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ROLLBACK $deployment_id $config_version $backend_digest" \
    >> /opt/tamaso/deployment-failures.log
}
trap rollback ERR

# --- Pull images by digest ---
docker compose --env-file .env pull

# --- Show migration plan ---
docker compose --env-file .env run --rm backend \
  python backend/manage.py migrate --plan

# --- Stop old containers for migration ---
docker compose --env-file .env stop frontend backend

# --- Apply migrations ---
docker compose --env-file .env run --rm backend \
  python backend/manage.py migrate --noinput

# --- Collect static assets ---
docker compose --env-file .env run --rm backend \
  python backend/manage.py collectstatic --noinput

# --- Start new containers and wait for health (180s timeout) ---
docker compose --env-file .env up -d --remove-orphans --wait --wait-timeout 180

# --- Clear rollback trap on success ---
trap - ERR

# --- Record successful deployment ---
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"timestamp":"%s","customer_id":"%s","deployment_id":"%s","config_version":"%s","backend_digest":"%s","frontend_digest":"%s","platform_version":"%s","status":"SUCCESS"}\n' \
  "$ts" "$CUSTOMER_ID" "$deployment_id" "$config_version" "$backend_digest" "$frontend_digest" "${PLATFORM_VERSION:-unknown}" \
  >> /opt/tamaso/deployments.json

# --- Cleanup ---
docker logout "$registry" >/dev/null
rm -f .env.rollback

echo "Deployed ${CUSTOMER_ID} · config ${config_version} · ${deployment_id}"
echo "  backend:  ${backend_digest}"
echo "  frontend: ${frontend_digest}"
