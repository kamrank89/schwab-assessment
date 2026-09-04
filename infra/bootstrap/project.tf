resource "google_project" "assessment" {
  count = var.create_project ? 1 : 0

  name            = var.project_name
  project_id      = var.project_id
  billing_account = var.billing_account
  folder_id       = var.folder_id
  org_id          = var.organization_id

  auto_create_network = false
  deletion_policy     = "ABANDON"
}

data "google_project" "effective" {
  project_id = local.effective_project_id

  depends_on = [google_project.assessment]
}
