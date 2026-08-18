terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Enable required APIs ---

resource "google_project_service" "iap" {
  service            = "iap.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

locals {
  # Normalize customer_id for resource naming (lowercase, hyphens)
  customer_slug = lower(replace(var.customer_id, "/[^a-zA-Z0-9]/", "-"))
  vm_name       = "tamaso-${local.customer_slug}"
  app_host      = var.app_host != "" ? var.app_host : "${google_compute_address.static_ip.address}.sslip.io"

  labels = merge(var.labels, {
    managed-by  = "terraform"
    customer    = local.customer_slug
    application = "tamaso"
  })
}

# --- Static IP ---

resource "google_compute_address" "static_ip" {
  name         = "${local.vm_name}-ip"
  region       = var.region
  address_type = "EXTERNAL"
  labels       = local.labels
}

# --- Service Account ---

resource "google_service_account" "vm" {
  account_id   = "${local.vm_name}-sa"
  display_name = "Tamaso VM - ${var.customer_id}"
}

# Artifact Registry reader (pull images)
resource "google_project_iam_member" "ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# GCS object admin (backup uploads)
resource "google_project_iam_member" "gcs_backup" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.vm.email}"
  condition {
    title      = "backup-bucket-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.backups.name}\")"
  }
}

# --- Backup Bucket ---

resource "google_storage_bucket" "backups" {
  name     = "${var.project_id}-tamaso-${local.customer_slug}-backups"
  location = var.region

  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }

  labels = local.labels
}

# --- Django Secret Key ---

resource "random_password" "django_secret" {
  length  = 64
  special = false
}

# --- Compute Instance ---

resource "google_compute_instance" "vm" {
  name         = local.vm_name
  machine_type = var.machine_type
  zone         = var.zone

  tags   = ["tamaso-http", "tamaso-ssh"]
  labels = local.labels

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {
      nat_ip = google_compute_address.static_ip.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = templatefile("${path.module}/startup.sh.tpl", {
      customer_id       = var.customer_id
      deploy_repo_url   = var.deploy_repo_url
      gcp_region        = var.ar_region
      gcp_project_id    = var.project_id
      ar_repository     = var.ar_repository
      image_prefix      = var.image_prefix
      gcs_backup_bucket = google_storage_bucket.backups.name
      platform_version  = var.platform_version
      app_host          = local.app_host
      acme_email        = var.acme_email
      django_secret_key = random_password.django_secret.result
      vulcan_variant    = var.vulcan_variant
    })
  }

  # Allow stopping for updates
  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [
      # Don't re-run startup script on subsequent applies
      metadata["startup-script"],
    ]
  }
}
