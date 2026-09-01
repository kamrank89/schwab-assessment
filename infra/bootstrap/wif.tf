resource "google_iam_workload_identity_pool" "github_actions" {
  project = local.effective_project_id

  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "Keyless identity federation for GitHub Actions"

  depends_on = [google_project_service.required["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project = local.effective_project_id

  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"
  description                        = "Trust for the configured GitHub repository main branch"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.actor_id"            = "assertion.actor_id"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
  }

  attribute_condition = "assertion.repository_id == '${var.github_repository_id}' && assertion.repository_owner_id == '${var.github_owner_id}' && assertion.sub == '${local.allowed_subject}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
    allowed_audiences = [
      "https://iam.googleapis.com/projects/${data.google_project.effective.number}/locations/global/workloadIdentityPools/github-actions/providers/github",
    ]
  }
}
