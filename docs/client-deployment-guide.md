# Client Deployment Guide

This document covers the complete process of deploying Vulcan/Tamaso to a client's GCP environment, from initial setup to ongoing operations.

---

## Overview

Vulcan is deployed as two Docker containers (backend + frontend) on a single GCE VM, with Caddy as a reverse proxy handling TLS. The application uses SQLite for persistence and Google Cloud Storage for backups.

```
Client's GCP Project
├── GCE VM (e2-small, Debian 12)
│   ├── Docker Compose
│   │   ├── backend (Django/Gunicorn)
│   │   ├── frontend (Next.js)
│   │   ├── caddy (reverse proxy + TLS)
│   │   └── data-init (volume permissions)
│   ├── /var/lib/tamaso/<CUSTOMER_ID>/data/    ← SQLite DB
│   ├── /var/lib/tamaso/<CUSTOMER_ID>/backups/ ← Local backup copies
│   └── /opt/tamaso/                           ← Deploy scripts + .env
├── Static IP
├── GCS Bucket (backups)
├── Service Account (AR reader + GCS writer)
└── Firewall Rules (HTTP/HTTPS + SSH via IAP)
```

---

## Prerequisites

### On our side (Tamaso)
- Application images built and pushed to our Artifact Registry
- `vulcan-deploy` repo accessible (GitHub)
- Terraform >= 1.5 installed locally or in Cloud Shell

### On the client's side
- A GCP project with billing enabled
- APIs enabled: Compute Engine, Artifact Registry, IAM, Cloud Storage
- A user with Owner or Editor role (for initial setup)
- A domain name pointed to the static IP (or use `<IP>.sslip.io` for testing)

### Cross-project image access
If deploying to the client's own GCP project (different from ours), grant their VM's service account read access to our Artifact Registry:

```bash
# Run in OUR project
gcloud artifacts repositories add-iam-policy-binding vulcan \
  --project=gentle-broker-505219-d0 \
  --location=us-central1 \
  --member="serviceAccount:<CLIENT_VM_SA>@<CLIENT_PROJECT>.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

---

## Deployment Steps

### Step 1: Provision Infrastructure (Terraform)

```bash
git clone https://github.com/harsh-kr-jha/vulcan-deploy.git
cd vulcan-deploy/terraform

cat > terraform.tfvars << EOF
project_id        = "<CLIENT_PROJECT_ID>"
region            = "asia-south1"
zone              = "asia-south1-b"
customer_id       = "<CLIENT_CODE>"
image_prefix      = "<TEMPLATE>-<CLIENT_CODE_LOWERCASE>"
ar_region         = "us-central1"
ar_repository     = "vulcan"
machine_type      = "e2-small"
boot_disk_size_gb = 20
acme_email        = "<CLIENT_ADMIN_EMAIL>"
vulcan_variant    = "automotive"
platform_version  = "1.0.1"
app_host          = "<CLIENT_DOMAIN>"
EOF

terraform init
terraform plan    # Review
terraform apply   # Confirm with 'yes'
```

Terraform creates: VM, static IP, firewall rules, service account, backup bucket, and runs the bootstrap startup script.

### Step 2: Wait for Bootstrap

The VM startup script takes 2-3 minutes. Verify:

```bash
gcloud compute ssh <VM_NAME> \
  --zone=<ZONE> \
  --project=<PROJECT_ID> \
  --tunnel-through-iap \
  --command="cat /opt/tamaso/.bootstrap-complete && echo 'READY' || echo 'STILL BOOTSTRAPPING'"
```

If issues, check logs:
```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="sudo journalctl -u google-startup-scripts --no-pager -n 50"
```

### Step 3: Deploy Application

Get the image digests:
```bash
BACKEND_DIGEST=$(gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/gentle-broker-505219-d0/vulcan/<IMAGE_PREFIX>-backend:<VERSION> \
  --format="value(image_summary.digest)")

FRONTEND_DIGEST=$(gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/gentle-broker-505219-d0/vulcan/<IMAGE_PREFIX>-frontend:<VERSION> \
  --format="value(image_summary.digest)")
```

Deploy:
```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="sudo /opt/tamaso/deploy.sh '${BACKEND_DIGEST}' '${FRONTEND_DIGEST}' '<CLIENT_CODE>-C01' '<deployment-id>'"
```

### Step 4: Create Admin User

```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="cd /opt/tamaso && sudo docker compose --env-file .env run --rm \
    -e DJANGO_SUPERUSER_EMAIL=<ADMIN_EMAIL> \
    -e DJANGO_SUPERUSER_USERNAME=admin \
    -e DJANGO_SUPERUSER_PASSWORD=<STRONG_PASSWORD> \
    backend python backend/manage.py createsuperuser --noinput"
```

### Step 5: Seed Demo Data (optional)

```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="cd /opt/tamaso && sudo docker compose --env-file .env run --rm backend \
    python backend/manage.py seed_mypol --confirm-production-showcase"
```

---

## Testing Checklist

Run these checks after every deployment to verify the system is working correctly.

### Infrastructure Tests

| # | Test | Command | Expected |
|---|------|---------|----------|
| 1 | VM is running | `gcloud compute instances describe <VM> --format="value(status)"` | `RUNNING` |
| 2 | Static IP attached | `gcloud compute addresses describe <IP_NAME> --format="value(status)"` | `IN_USE` |
| 3 | Docker running | SSH → `sudo systemctl is-active docker` | `active` |
| 4 | All containers healthy | SSH → `sudo docker compose -f /opt/tamaso/compose.yaml ps` | All `Up (healthy)` |

### Application Health Tests

| # | Test | Command | Expected |
|---|------|---------|----------|
| 5 | Backend health endpoint | `curl -sf https://<HOST>/api/backend/health/` | 200 OK |
| 6 | Frontend loads | `curl -sf -o /dev/null -w "%{http_code}" https://<HOST>/` | `200` |
| 7 | Admin panel accessible | `curl -sf -o /dev/null -w "%{http_code}" https://<HOST>/admin/login/` | `200` |
| 8 | Static files served | `curl -sf -o /dev/null -w "%{http_code}" https://<HOST>/static/admin/css/base.css` | `200` |
| 9 | TLS valid | `curl -vI https://<HOST>/ 2>&1 \| grep "SSL certificate verify ok"` | Present |

### Functional Tests

| # | Test | How | Expected |
|---|------|-----|----------|
| 10 | Login works | Browser → login with demo credentials | Redirects to dashboard |
| 11 | API responds | `curl -sf https://<HOST>/api/backend/health/` | JSON response |
| 12 | Database writable | Create a user via admin panel | User appears in list |
| 13 | Backup works | SSH → `sudo /opt/tamaso/backup.sh` | "Backup uploaded: gs://..." |

### Security Tests

| # | Test | How | Expected |
|---|------|-----|----------|
| 14 | No open SSH to internet | `nmap -p 22 <IP>` from external machine | `filtered` |
| 15 | SSH only via IAP | Direct SSH from internet | Connection refused |
| 16 | HTTPS enforced | `curl -I http://<HOST>/` | 301 redirect to https |
| 17 | Security headers present | `curl -I https://<HOST>/` | Has X-Frame-Options, X-Content-Type-Options |
| 18 | .env not exposed | `curl https://<HOST>/.env` | 404 |

### Quick Smoke Test Script

Run this after deployment for a quick pass/fail:

```bash
#!/usr/bin/env bash
# smoke-test.sh <app_host>
set -euo pipefail

HOST="${1:?Usage: smoke-test.sh <app_host>}"

echo "Testing: ${HOST}"
echo "---"

# Health
printf "%-30s" "Backend health..."
curl -sf "https://${HOST}/api/backend/health/" > /dev/null && echo "PASS" || echo "FAIL"

# Frontend
printf "%-30s" "Frontend loads..."
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "https://${HOST}/")
[[ "$STATUS" == "200" ]] && echo "PASS" || echo "FAIL (${STATUS})"

# Admin
printf "%-30s" "Admin panel..."
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "https://${HOST}/admin/login/")
[[ "$STATUS" == "200" ]] && echo "PASS" || echo "FAIL (${STATUS})"

# TLS
printf "%-30s" "TLS certificate..."
curl -vI "https://${HOST}/" 2>&1 | grep -q "SSL certificate verify ok" && echo "PASS" || echo "FAIL"

# HTTPS redirect
printf "%-30s" "HTTP → HTTPS redirect..."
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "http://${HOST}/")
[[ "$STATUS" == "301" || "$STATUS" == "308" ]] && echo "PASS" || echo "FAIL (${STATUS})"

echo "---"
echo "Done."
```

---

## Ongoing Operations

### Updating the Application

1. Push code to `client/<TEMPLATE>/<CLIENT_CODE>` branch
2. `build-artifact.yml` runs automatically, pushes new images
3. Trigger `deploy-customer.yml` with new digests (GitHub Actions UI or API)
4. `deploy.sh` handles: backup → pull → migrate → restart → health check

### Manual Deployment (if GitHub Actions not configured for client)

```bash
# Get new digests
BACKEND_DIGEST=$(gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/gentle-broker-505219-d0/vulcan/<PREFIX>-backend:<NEW_VERSION> \
  --format="value(image_summary.digest)")
FRONTEND_DIGEST=$(gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/gentle-broker-505219-d0/vulcan/<PREFIX>-frontend:<NEW_VERSION> \
  --format="value(image_summary.digest)")

# Deploy
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="sudo /opt/tamaso/deploy.sh '${BACKEND_DIGEST}' '${FRONTEND_DIGEST}' '<CLIENT>-C02' '<deploy-id>'"
```

### Rollback

If a deployment fails, `deploy.sh` automatically rolls back. For manual rollback:

```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="cd /opt/tamaso && sudo cp .env.rollback .env && sudo docker compose --env-file .env up -d --wait"
```

### Viewing Logs

```bash
# All services
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="cd /opt/tamaso && sudo docker compose logs --tail=100"

# Specific service
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="cd /opt/tamaso && sudo docker compose logs backend --tail=50"
```

### Backup & Restore

**Manual backup:**
```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="sudo /opt/tamaso/backup.sh"
```

**List backups:**
```bash
gsutil ls gs://<BACKUP_BUCKET>/sqlite/<CUSTOMER_ID>/
```

**Restore from backup:**
```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap --command="
  cd /opt/tamaso
  sudo docker compose stop backend frontend
  sudo cp /var/lib/tamaso/<CUSTOMER_ID>/data/tamaso.sqlite3 /var/lib/tamaso/<CUSTOMER_ID>/data/tamaso.sqlite3.old
  gsutil cp gs://<BUCKET>/sqlite/<CUSTOMER_ID>/<BACKUP_FILE> /tmp/restore.sqlite3
  sudo cp /tmp/restore.sqlite3 /var/lib/tamaso/<CUSTOMER_ID>/data/tamaso.sqlite3
  sudo chown 10001:10001 /var/lib/tamaso/<CUSTOMER_ID>/data/tamaso.sqlite3
  sudo docker compose up -d --wait
"
```

### Monitoring

Check deployment history:
```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="cat /opt/tamaso/deployments.json"
```

Check container resource usage:
```bash
gcloud compute ssh <VM_NAME> --tunnel-through-iap \
  --command="sudo docker stats --no-stream"
```

---

## Tear Down

To completely remove a client deployment:

```bash
cd vulcan-deploy/terraform
terraform destroy
```

This removes: VM, static IP, firewall rules, service account, IAM bindings.

The backup bucket is protected (`force_destroy = false`). To remove it:
1. Empty the bucket: `gsutil -m rm -r gs://<BUCKET>/**`
2. Set `force_destroy = true` in `main.tf`
3. Run `terraform destroy` again

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `curl: connection refused` | Containers not running | SSH → `sudo docker compose -f /opt/tamaso/compose.yaml up -d` |
| `502 Bad Gateway` | Backend crashed | SSH → `sudo docker compose logs backend --tail=30` |
| `Certificate error` | Caddy hasn't provisioned TLS yet | Wait 1-2 minutes, or check `sudo docker compose logs caddy` |
| `STILL BOOTSTRAPPING` | Startup script failed | Check `sudo journalctl -u google-startup-scripts` |
| Deploy fails with "backup failed" | No GCS bucket access | Check SA permissions with `gcloud projects get-iam-policy` |
| 400 Bad Request on admin | `DJANGO_ALLOWED_HOSTS` mismatch | Check `.env` matches the actual domain |
| Frontend shows for `/admin/` | Browser cache | Try incognito, or hard refresh |

---

## GitHub Actions Setup (for automated deployments)

To enable the GitHub Action workflow for a client:

1. Create GitHub environment `gcp-<CLIENT_CODE>` with variables:
   - `GCE_INSTANCE` = VM name
   - `GCE_ZONE` = VM zone
   - `GCP_PROJECT_ID` = client project ID
   - `APP_URL` = `https://<domain>`
   - `GCP_WORKLOAD_IDENTITY_PROVIDER` = WIF provider (if client's project)
   - `GCP_DEPLOY_SERVICE_ACCOUNT` = deploy SA email

2. Grant the deploy SA these roles on the client project:
   - `roles/iap.tunnelResourceAccessor`
   - `roles/compute.instanceAdmin.v1`
   - `roles/compute.osLogin`

3. Trigger workflow: **Actions → Deploy to Customer GCE → Run workflow**

---

## Cost Estimate (per client)

| Resource | Monthly cost |
|----------|-------------|
| e2-small VM (24/7) | ~$12-14 |
| 20GB pd-balanced disk | ~$2 |
| Static IP (attached) | Free |
| GCS backups (< 1GB) | < $1 |
| Egress (light traffic) | < $1 |
| **Total** | **~$15-18/month** |

Scale down with `e2-micro` (~$7/month) for low-traffic clients, or stop the VM when not in use.
