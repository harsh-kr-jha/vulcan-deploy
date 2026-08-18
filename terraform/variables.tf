variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the VM and networking"
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "GCP zone for the VM"
  type        = string
  default     = "asia-south1-b"
}

variable "customer_id" {
  description = "Customer identifier (e.g. MYPOL, INFINEXXGEN)"
  type        = string
}

variable "image_prefix" {
  description = "Artifact Registry image prefix (e.g. mfg-da-auto-all-mypol)"
  type        = string
}

variable "ar_region" {
  description = "Artifact Registry region (where images are stored)"
  type        = string
  default     = "us-central1"
}

variable "ar_repository" {
  description = "Artifact Registry repository name"
  type        = string
  default     = "vulcan"
}

variable "machine_type" {
  description = "GCE machine type"
  type        = string
  default     = "e2-small"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20
}

variable "app_host" {
  description = "Application hostname (e.g. 1.2.3.4.sslip.io or custom domain). Leave empty to auto-generate from static IP."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Email for Let's Encrypt TLS certificates"
  type        = string
}

variable "vulcan_variant" {
  description = "Application variant (automotive, mushroom, agri)"
  type        = string
  default     = "automotive"
}

variable "platform_version" {
  description = "Platform version tag (matches VERSION file in vulcan repo)"
  type        = string
  default     = "1.0.1"
}

variable "deploy_repo_url" {
  description = "Git URL for the vulcan-deploy repo"
  type        = string
  default     = "https://github.com/harsh-kr-jha/vulcan-deploy.git"
}

variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default     = {}
}
