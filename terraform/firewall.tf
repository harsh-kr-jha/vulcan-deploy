# --- Firewall Rules ---

resource "google_compute_firewall" "allow_http_https" {
  name    = "tamaso-allow-http-https"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["tamaso-http"]

  description = "Allow HTTP/HTTPS traffic to Tamaso instances"
}

resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "tamaso-allow-ssh-iap"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP's IP range for TCP forwarding
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["tamaso-ssh"]

  description = "Allow SSH via IAP tunnel to Tamaso instances"
}
