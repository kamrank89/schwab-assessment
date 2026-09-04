resource "google_gke_hub_membership" "assessment" {
  for_each = google_container_cluster.assessment

  project       = local.project_id
  location      = "global"
  membership_id = each.value.name

  labels = local.assessment_labels

  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${each.value.id}"
    }
  }

  authority {
    issuer = "https://container.googleapis.com/v1/${each.value.id}"
  }
}
