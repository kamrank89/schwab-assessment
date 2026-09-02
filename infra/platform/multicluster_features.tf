resource "google_gke_hub_feature" "multiclusterservicediscovery" {
  project  = local.project_id
  name     = "multiclusterservicediscovery"
  location = "global"

  labels = local.assessment_labels

  depends_on = [google_gke_hub_membership.assessment]
}

resource "google_gke_hub_feature" "multiclusteringress" {
  project  = local.project_id
  name     = "multiclusteringress"
  location = "global"

  labels = local.assessment_labels

  spec {
    multiclusteringress {
      config_membership = google_gke_hub_membership.assessment["us-central1"].id
    }
  }

  depends_on = [
    google_gke_hub_membership.assessment["us-central1"],
    google_gke_hub_membership.assessment["us-east1"],
    google_gke_hub_feature.multiclusterservicediscovery,
  ]
}
