locals {
  effective_project_id = var.project_id
  allowed_subject      = "repo:${var.github_repository}:ref:refs/heads/main"

  required_services = toset([
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

  pipeline_project_roles = toset([
    "roles/bigquery.admin",
    "roles/compute.admin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/gkehub.admin",
    "roles/gkehub.gatewayAdmin",
    "roles/gkehub.viewer",
    "roles/iam.serviceAccountAdmin",
    "roles/logging.configWriter",
    "roles/monitoring.viewer",
    "roles/resourcemanager.projectIamAdmin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  pipeline_state_bucket_roles = toset([
    "roles/storage.legacyBucketReader",
    "roles/storage.objectAdmin",
  ])
}
