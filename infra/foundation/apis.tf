resource "google_project_service" "required" {
  for_each = local.required_services

  project = local.project_id
  service = each.value

  disable_on_destroy = false
}
