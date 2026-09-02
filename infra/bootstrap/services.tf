resource "google_project_service" "required" {
  for_each = local.required_services

  project = local.effective_project_id
  service = each.value

  disable_on_destroy = false

  depends_on = [google_project.assessment]
}
