resource "google_storage_bucket" "terraform_state" {
  name     = var.state_bucket_name
  project  = local.effective_project_id
  location = var.state_bucket_location

  force_destroy               = false
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      num_newer_versions = 10
    }
  }

  depends_on = [google_project_service.required["storage.googleapis.com"]]
}
