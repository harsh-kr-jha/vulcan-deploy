#!/usr/bin/env bash
# Tamaso customer backup script.
#
# Creates a consistent SQLite backup and uploads it to GCS.
# Called automatically by deploy.sh before every deployment,
# and independently by the systemd timer for daily backups.
#
set -Eeuo pipefail

cd /opt/tamaso

if [[ ! -f .env ]]; then
  echo "Missing /opt/tamaso/.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${GCS_BACKUP_BUCKET:?GCS_BACKUP_BUCKET is required}"
: "${CUSTOMER_ID:?CUSTOMER_ID is required}"

data_root="/var/lib/tamaso/${CUSTOMER_ID}"
database_path="${data_root}/data/tamaso.sqlite3"

if [[ ! -f "$database_path" ]]; then
  echo "No SQLite database exists yet; there is nothing to back up."
  exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="tamaso-${CUSTOMER_ID}-${timestamp}.sqlite3"
container_backup_path="/backups/${backup_name}"
host_backup_path="${data_root}/backups/${backup_name}"

# Online backup via Python sqlite3.backup()
docker compose --env-file .env run --rm --no-deps \
  -e "BACKUP_PATH=${container_backup_path}" \
  backend python -c \
  "import os, sqlite3; source=sqlite3.connect('/data/tamaso.sqlite3'); target=sqlite3.connect(os.environ['BACKUP_PATH']); source.backup(target); target.close(); source.close()"

test -s "$host_backup_path"

# Upload to GCS using instance metadata token
access_token="$(
  curl --fail --silent --show-error \
    -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
)"
object_name="sqlite/${CUSTOMER_ID}/${backup_name}"
encoded_object_name="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$object_name")"

curl --fail --silent --show-error \
  -X POST \
  -H "Authorization: Bearer ${access_token}" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary "@${host_backup_path}" \
  "https://storage.googleapis.com/upload/storage/v1/b/${GCS_BACKUP_BUCKET}/o?uploadType=media&name=${encoded_object_name}" \
  >/dev/null

# Remove local backups older than 7 days
find "${data_root}/backups" -type f -name "tamaso-${CUSTOMER_ID}-*.sqlite3" \
  -mtime +7 -delete

echo "Backup uploaded: gs://${GCS_BACKUP_BUCKET}/${object_name}"
