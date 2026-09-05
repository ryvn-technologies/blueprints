# Create a private DNS zone for internal use
resource "google_dns_managed_zone" "internal" {
  count       = var.skip_dns_provisioning ? 0 : 1
  name        = "internal-zone-${var.environment}"
  dns_name    = "${var.internal_root_domain}."
  description = "Internal private DNS zone"

  visibility = "private"

  # Records are wiped on destroy only while deletion protection is off; a
  # protected zone that still holds records refuses to be deleted.
  force_destroy = !var.deletion_protection

  private_visibility_config {
    networks {
      network_url = module.gcp-network.network_self_link
    }
  }
}

# Create a public DNS zone
resource "google_dns_managed_zone" "public" {
  count       = var.skip_dns_provisioning ? 0 : 1
  name        = "public-zone-${var.environment}"
  dns_name    = "${var.public_root_domain}."
  description = "Public DNS zone"

  visibility = "public"

  force_destroy = !var.deletion_protection
}

# Add CAA records to the public zone
resource "google_dns_record_set" "caa" {
  count        = var.skip_dns_provisioning ? 0 : 1
  name         = "${var.public_root_domain}."
  managed_zone = google_dns_managed_zone.public[0].name
  type         = "CAA"
  ttl          = 300

  rrdatas = [
    "0 issue \"letsencrypt.org\"",
    "0 issue \"pki.goog\""
  ]
}
