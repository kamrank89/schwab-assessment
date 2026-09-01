resource "google_compute_router" "cluster" {
  for_each = local.cluster_networks

  project = local.project_id
  name    = "gke-assessment-${each.key}-router"
  region  = each.key
  network = google_compute_network.assessment.id
}

resource "google_compute_router_nat" "cluster" {
  for_each = local.cluster_networks

  project = local.project_id
  name    = "gke-assessment-${each.key}-nat"
  region  = each.key
  router  = google_compute_router.cluster[each.key].name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
