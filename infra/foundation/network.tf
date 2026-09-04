resource "google_compute_network" "assessment" {
  project = local.project_id
  name    = "schwab-assessment"

  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"

  depends_on = [google_project_service.required["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "cluster" {
  for_each = local.cluster_networks

  project       = local.project_id
  name          = "gke-assessment-${each.key}"
  region        = each.key
  network       = google_compute_network.assessment.id
  ip_cidr_range = each.value.subnet_cidr

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = each.value.pod_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = each.value.service_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.1
    metadata             = "INCLUDE_ALL_METADATA"
  }
}
