resource "google_service_account" "pipeline" {
  project = local.effective_project_id

  account_id   = "assessment-deployer"
  display_name = "Assessment deployer"
  description  = "GitHub Actions identity for assessment delivery"

  depends_on = [google_project_service.required["iam.googleapis.com"]]
}

resource "google_service_account_iam_member" "github_repository" {
  service_account_id = google_service_account.pipeline.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository_id/${var.github_repository_id}"
}

resource "google_project_iam_member" "pipeline" {
  for_each = local.pipeline_project_roles

  project = local.effective_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.pipeline.email}"
}

resource "google_storage_bucket_iam_member" "pipeline" {
  for_each = local.pipeline_state_bucket_roles

  bucket = google_storage_bucket.terraform_state.name
  role   = each.value
  member = "serviceAccount:${google_service_account.pipeline.email}"
}
