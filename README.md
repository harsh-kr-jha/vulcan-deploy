# Vulcan Deploy

Deployment configuration for Tamaso/Vulcan customer instances.

This repo contains everything needed to deploy Vulcan on a GCE VM — no source code required.
Application images are pulled from Google Artifact Registry by digest.

## Architecture

```
GitHub (vulcan repo)          Artifact Registry           Customer VM
─────────────────────         ─────────────────           ───────────
push to client/* branch  ──>  backend image (digest)  <── deploy.sh pulls
                              frontend image (digest)     compose.yaml runs
                                                          Caddy terminates TLS
```

## Files

| File | Purpose |
|------|---------|
| `compose.yaml` | Docker Compose service definitions |
| `Caddyfile` | Reverse proxy + auto-TLS configuration |
| `deploy.sh` | Deployment script (pull, migrate, health check, rollback) |
| `backup.sh` | SQLite backup + GCS upload |
| `bootstrap.sh` | One-time VM setup (Docker, directories, systemd timer) |
| `vulcan-backup.service` | Systemd service unit for daily backup |
| `vulcan-backup.timer` | Systemd timer (daily at 02:00 UTC) |
| `.env.example` | Template for the customer environment file |

## Quick Start

### 1. Create the VM

```bash
gcloud compute instances create <vm-name> \
  --project=<project-id> \
  --zone=asia-south1-b \
  --machine-type=e2-small \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=20GB \
  --tags=http-server,https-server \
  --address=<static-ip-name> \
  --scopes=cloud-platform
```

### 2. Bootstrap

```bash
# Clone this repo onto the VM
gcloud compute ssh <vm-name> --zone=asia-south1-b
git clone https://github.com/<org>/vulcan-deploy.git /tmp/vulcan-deploy
sudo /tmp/vulcan-deploy/bootstrap.sh <CUSTOMER_ID>
```

### 3. Configure

```bash
sudo cp /tmp/vulcan-deploy/.env.example /opt/tamaso/.env
sudo chmod 0600 /opt/tamaso/.env
sudo nano /opt/tamaso/.env  # Fill in real values
```

### 4. Deploy

Either trigger the GitHub Action workflow, or run manually:

```bash
sudo /opt/tamaso/deploy.sh \
  'sha256:<backend-digest>' \
  'sha256:<frontend-digest>' \
  'CUSTOMER-C01' \
  'customer-deploy-01'
```

### 5. Seed demo data (optional)

```bash
cd /opt/tamaso
sudo docker compose --env-file .env run --rm backend \
  python backend/manage.py seed_mypol --confirm-production-showcase
```

## Deploying via GitHub Action

After initial bootstrap, all subsequent deployments are automated via the
`Deploy to Customer GCE` workflow in the main vulcan repo. It:

1. Authenticates to GCP via Workload Identity
2. SCPs these deployment files to the VM
3. Runs `deploy.sh` with the artifact digests
4. Verifies application health

No manual SSH required after bootstrap.

## Backup & Restore

- **Automatic**: systemd timer runs `backup.sh` daily at 02:00 UTC
- **Pre-deploy**: `deploy.sh` always runs `backup.sh` before any changes
- **Restore**: Stop backend, replace `/var/lib/tamaso/<ID>/data/tamaso.sqlite3`
  with a backup, fix ownership (`chown 10001:10001`), restart

## Security

- VM service account needs: `roles/artifactregistry.reader`, `roles/storage.objectAdmin` (for backup bucket)
- `.env` file is `0600` on the VM, never committed to git
- Images are pinned by digest (immutable, not just by tag)
- Caddy auto-provisions TLS via Let's Encrypt
