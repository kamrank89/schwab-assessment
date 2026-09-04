resource "google_secret_manager_secret" "app_a" {
  project   = local.project_id
  secret_id = "app-a-demo"

  labels = {
    application = "app-a"
    environment = "assessment"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.required["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret" "grafana_admin" {
  project   = local.project_id
  secret_id = "grafana-admin"

  labels = {
    application = "grafana"
    environment = "assessment"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.required["secretmanager.googleapis.com"]]
}
