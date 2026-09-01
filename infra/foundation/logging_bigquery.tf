resource "google_bigquery_dataset" "assessment_logs" {
  project    = local.project_id
  dataset_id = "assessment_logs"
  location   = "US"

  friendly_name                   = "Assessment logs"
  description                     = "Partitioned GKE, load-balancer, and Kubernetes audit logs"
  default_partition_expiration_ms = 2592000000
  delete_contents_on_destroy      = true

  labels = {
    environment = "assessment"
    managed_by  = "terraform"
  }

  depends_on = [google_project_service.required["bigquery.googleapis.com"]]
}

resource "google_logging_project_sink" "bigquery" {
  project = local.project_id
  name    = "assessment-logs-bigquery"

  destination = "bigquery.googleapis.com/projects/${local.project_id}/datasets/${google_bigquery_dataset.assessment_logs.dataset_id}"
  filter      = <<-EOT
    resource.type=("k8s_container" OR "k8s_node" OR "k8s_control_plane_component" OR "k8s_cluster" OR "http_load_balancer")
    OR (resource.type="gke_cluster" AND protoPayload.serviceName="container.googleapis.com")
  EOT

  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }

  depends_on = [google_project_service.required["logging.googleapis.com"]]
}

resource "google_bigquery_dataset_iam_member" "logging_sink" {
  project    = local.project_id
  dataset_id = google_bigquery_dataset.assessment_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.bigquery.writer_identity
}
