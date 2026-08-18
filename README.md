# Vulcan Deploy

Deployment configuration for Tamaso/Vulcan customer instances.

This repo contains everything needed to provision infrastructure and deploy Vulcan
on a GCE VM — no source code required. Application images are pulled from
Google Artifact Registry by digest.

## Architecture

```
GitHub (vulcan repo)          Artifact Registry           Customer VM
─────────────────────         ─────────────────           ───────────
push to client/* branch  ──>  backend image (digest)  <── deploy.sh pulls
                              frontend image (digest)     compose.yaml runs
                                                          Caddy terminates TLS

Terraform (this repo)         GCP
─────────────────────         ───
terraform apply          ──>  VM + IP + firewall + SA + bucket + bootstrap
```

## Quick Start (Terraform)

This is the recommended way to provision a new customer environment.

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- `gcloud` CLI authenticated with project owner/editor permissions
- Application images already built in Artifact Registry

### Provision

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with customer values

terraform init
terraform plan
terraform apply
```

Terraform will:
1. Reserve a static external IP
2. Create a dedicated service account with AR reader + GCS backup permissions
3. Create a GCS bucket for SQLite backups
4. Create firewall rules (HTTP/HTTPS + SSH via IAP)
5. Create the VM with a startup script that installs Docker, runs bootstrap, and writes `.env`

### Deploy the application

After `terraform apply` completes, wait ~2 minutes for the startup script, then:

```bash
# Get the digests
BACKEND_DIGEST=$(gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/PROJECT/vulcan/IMAGE_PREFIX-backend:VERSION \
  --format="value(image_summary.digest)")
FRONTEND_DIGEST=$(gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/PROJECT/vulcan/IMAGE_PREFIX-frontend:VERSION \
  --format="value(image_summary.digest)")

# Deploy (use the ssh_command from terraform output)
gcloud compute ssh VM_NAME --zone=ZONE --tunnel-through-iap \
  --command="sudo /opt/tamaso/deploy.sh '${BACKEND_DIGEST}' '${FRONTEND_DIGEST}' 'CUSTOMER-C01' 'customer-001'"
```

Or trigger the `Deploy to Customer GCE` GitHub Action workflow.

### Tear down

```bash
terraform destroy
```

This removes all infrastructure. The backup bucket is protected by default — Terraform will fail
to destroy it if it contains objects. Empty it first or set `force_destroy = true` in the config.

## File Structure

```
vulcan-deploy/
├── terraform/
│   ├── main.tf                    ← VM, service account, disk, IP
│   ├── variables.tf               ← All configurable inputs
│   ├── outputs.tf                 ← IP, URL, SSH command, etc.
│   ├── firewall.tf                ← HTTP/HTTPS + IAP SSH rules
│   ├── startup.sh.tpl             ← VM bootstrap template
│   ├── terraform.tfvars.example   ← Example variable values
│   └── .gitignore                 ← Ignore state + secrets
├── compose.yaml                   ← Docker Compose service definitions
├── Caddyfile                      ← Reverse proxy + auto-TLS
├── deploy.sh                      ← Pull, migrate, deploy, rollback
├── backup.sh                      ← SQLite backup → GCS
├── bootstrap.sh                   ← One-time VM setup script
├── vulcan-backup.service          ← Systemd daily backup unit
├── vulcan-backup.timer            ← Systemd timer (02:00 UTC)
├── .env.example                   ← Environment variable template
└── README.md
```

## Deployment Lifecycle

| When | Who | What |
|------|-----|------|
| New customer | You | `terraform apply` (once) |
| Every release | GitHub Action | `deploy-customer.yml` → deploy.sh |
| Tear down | You | `terraform destroy` |

After Terraform provisions the infrastructure, you never need to manually SSH
or run Cloud Shell commands. The GitHub Action handles all subsequent deployments.

## Manual Bootstrap (without Terraform)

If you prefer not to use Terraform:

1. Create VM manually (see below)
2. SSH in and run `bootstrap.sh <CUSTOMER_ID>`
3. Write `/opt/tamaso/.env` (see `.env.example`)
4. Run `deploy.sh` with artifact digests

```bash
gcloud compute instances create <vm-name> \
  --project=<project-id> \
  --zone=asia-south1-b \
  --machine-type=e2-small \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=20GB \
  --tags=tamaso-http,tamaso-ssh \
  --address=<static-ip-name> \
  --scopes=cloud-platform
```

## Backup & Restore

- **Automatic**: systemd timer runs `backup.sh` daily at 02:00 UTC
- **Pre-deploy**: `deploy.sh` always runs `backup.sh` before any changes
- **Restore**: Stop backend, replace `/var/lib/tamaso/<ID>/data/tamaso.sqlite3`
  with a backup, fix ownership (`chown 10001:10001`), restart

## Security

- VM service account has minimal permissions (AR reader + backup bucket only)
- `.env` file is `0600` on the VM, never committed to git
- Images are pinned by digest (immutable)
- SSH only via IAP tunnel (no public SSH port)
- Caddy auto-provisions TLS via Let's Encrypt
- Terraform state contains secrets — store it in a remote backend (GCS) with encryption
