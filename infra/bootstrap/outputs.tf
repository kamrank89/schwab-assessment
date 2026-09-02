output "effective_project_id" {
  description = "The GCP project ID used by the bootstrap resources."
  value       = local.effective_project_id
}

output "project_number" {
  description = "The numeric identifier of the GCP project."
  value       = data.google_project.effective.number
}

output "terraform_state_bucket" {
  description = "The name of the Terraform state bucket."
  value       = google_storage_bucket.terraform_state.name
}

output "wif_provider_resource_name" {
  description = "The resource name of the GitHub Workload Identity Federation provider."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "pipeline_service_account_email" {
  description = "The email address of the GitHub pipeline service account."
  value       = google_service_account.pipeline.email
}

output "github_repository" {
  description = "The GitHub repository allowed to deploy."
  value       = var.github_repository
}

output "allowed_subject" {
  description = "The exact GitHub OIDC subject allowed to deploy."
  value       = local.allowed_subject
}
