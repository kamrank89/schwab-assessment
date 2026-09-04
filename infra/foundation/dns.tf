resource "google_dns_managed_zone" "assessment" {
  count = var.manage_dns && var.create_dns_zone ? 1 : 0

  project = local.project_id
  name    = var.dns_zone_name

  dns_name    = lower(trimspace(var.dns_zone_dns_name))
  description = "Public DNS zone for the GKE assessment endpoint"
  visibility  = "public"

  labels = {
    environment = "assessment"
    managed_by  = "terraform"
  }

  depends_on = [google_project_service.required["dns.googleapis.com"]]
}

data "google_dns_managed_zone" "assessment" {
  count = var.manage_dns && !var.create_dns_zone ? 1 : 0

  project = local.project_id
  name    = var.dns_zone_name

  depends_on = [google_project_service.required["dns.googleapis.com"]]
}

locals {
  dns_zone_dns_name = !var.manage_dns ? null : (
    var.create_dns_zone
    ? google_dns_managed_zone.assessment[0].dns_name
    : data.google_dns_managed_zone.assessment[0].dns_name
  )
}

resource "google_dns_record_set" "assessment" {
  count = var.manage_dns ? 1 : 0

  project      = local.project_id
  managed_zone = var.dns_zone_name
  name         = local.normalized_dns_name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.ingress.address]

  lifecycle {
    precondition {
      condition = local.normalized_dns_name == lower(local.dns_zone_dns_name) || endswith(
        local.normalized_dns_name,
        ".${lower(local.dns_zone_dns_name)}",
      )
      error_message = "dns_name must belong to the selected Cloud DNS zone."
    }
  }

  depends_on = [google_dns_managed_zone.assessment]
}
