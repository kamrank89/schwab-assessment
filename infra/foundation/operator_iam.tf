locals {
  cluster_admin_email  = lower(trimspace(var.cluster_admin_email))
  cluster_admin_member = "user:${local.cluster_admin_email}"
}

resource "google_project_iam_member" "cluster_admin_gateway" {
  for_each = toset([
    "roles/gkehub.gatewayAdmin",
    "roles/gkehub.gatewayReader",
  ])

  project = local.project_id
  role    = each.value
  member  = local.cluster_admin_member
}

resource "google_secret_manager_secret_iam_member" "cluster_admin_grafana" {
  project   = local.project_id
  secret_id = google_secret_manager_secret.grafana_admin.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.cluster_admin_member
}
