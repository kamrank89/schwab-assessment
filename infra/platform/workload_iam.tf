resource "google_service_account_iam_member" "app_a_workload_identity" {
  service_account_id = "projects/${local.project_id}/serviceAccounts/${local.foundation.app_a_runtime_gsa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_identity_pool}[assessment/app-a]"

  depends_on = [google_container_cluster.assessment]
}

resource "google_service_account_iam_member" "grafana_workload_identity" {
  service_account_id = "projects/${local.project_id}/serviceAccounts/${local.foundation.grafana_runtime_gsa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_identity_pool}[observability/grafana]"

  depends_on = [google_container_cluster.assessment]
}
