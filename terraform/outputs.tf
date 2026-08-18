output "vm_name" {
  description = "Name of the created VM"
  value       = google_compute_instance.vm.name
}

output "vm_zone" {
  description = "Zone of the created VM"
  value       = google_compute_instance.vm.zone
}

output "static_ip" {
  description = "External static IP address"
  value       = google_compute_address.static_ip.address
}

output "app_url" {
  description = "Application URL"
  value       = "https://${local.app_host}"
}

output "ssh_command" {
  description = "SSH command to access the VM"
  value       = "gcloud compute ssh ${google_compute_instance.vm.name} --zone=${google_compute_instance.vm.zone} --project=${var.project_id} --tunnel-through-iap"
}

output "deploy_command" {
  description = "Manual deploy command template"
  value       = "gcloud compute ssh ${google_compute_instance.vm.name} --zone=${google_compute_instance.vm.zone} --project=${var.project_id} --tunnel-through-iap --command=\"sudo /opt/tamaso/deploy.sh '<BACKEND_DIGEST>' '<FRONTEND_DIGEST>' '${var.customer_id}-C01' '${local.customer_slug}-001'\""
}

output "backup_bucket" {
  description = "GCS bucket for backups"
  value       = google_storage_bucket.backups.name
}

output "service_account" {
  description = "VM service account email"
  value       = google_service_account.vm.email
}

output "health_check_command" {
  description = "Command to verify the deployment"
  value       = "curl --fail --retry 5 --retry-delay 15 https://${local.app_host}/api/backend/health/"
}
