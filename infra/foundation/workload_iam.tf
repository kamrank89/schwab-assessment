resource "google_service_account" "app_a" {
  project = local.project_id

  account_id   = "app-a-runtime"
  display_name = "App A runtime"
  description  = "Workload Identity runtime for assessment/app-a"
}

resource "google_service_account" "grafana" {
  project = local.project_id

  account_id   = "grafana-runtime"
  display_name = "Grafana runtime"
  description  = "Workload Identity runtime for observability/grafana"
}

resource "google_service_account" "gke_nodes" {
  project = local.project_id

  account_id   = "gke-autopilot-nodes"
  display_name = "GKE Autopilot nodes"
  description  = "Dedicated node identity for the assessment Autopilot clusters"
}

resource "google_secret_manager_secret_iam_member" "app_a" {
  project   = local.project_id
  secret_id = google_secret_manager_secret.app_a.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_a.email}"
}

resource "google_secret_manager_secret_iam_member" "grafana" {
  project   = local.project_id
  secret_id = google_secret_manager_secret.grafana_admin.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.grafana.email}"
}

resource "google_project_iam_member" "grafana" {
  for_each = toset([
    "roles/bigquery.jobUser",
    "roles/monitoring.viewer",
  ])

  project = local.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.grafana.email}"
}

resource "google_bigquery_dataset_iam_member" "grafana" {
  project    = local.project_id
  dataset_id = google_bigquery_dataset.assessment_logs.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.grafana.email}"
}

resource "google_project_iam_member" "gke_node_role" {
  project = local.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_node_service_agent" {
  project = local.project_id
  role    = "roles/container.defaultNodeServiceAgent"
  member  = "serviceAccount:service-${local.project_number}@gcp-sa-gkenode.iam.gserviceaccount.com"
}

resource "google_service_account_iam_member" "pipeline_node_act_as" {
  service_account_id = google_service_account.gke_nodes.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.bootstrap_outputs.pipeline_service_account_email}"
}
