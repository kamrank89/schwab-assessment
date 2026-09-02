resource "google_compute_global_address" "ingress" {
  project = local.project_id
  name    = "schwab-assessment"

  address_type = "EXTERNAL"
  ip_version   = "IPV4"

  depends_on = [google_project_service.required["compute.googleapis.com"]]
}

resource "google_compute_ssl_policy" "assessment" {
  project = local.project_id
  name    = "schwab-assessment-tls"

  profile         = "MODERN"
  min_tls_version = "TLS_1_2"

  depends_on = [google_project_service.required["compute.googleapis.com"]]
}

resource "google_compute_managed_ssl_certificate" "assessment" {
  count = var.enable_https ? 1 : 0

  project = local.project_id
  name    = "schwab-assessment-certificate"

  managed {
    domains = [trimsuffix(lower(trimspace(var.dns_name)), ".")]
  }

  depends_on = [google_project_service.required["compute.googleapis.com"]]
}
