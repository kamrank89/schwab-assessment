resource "google_project_iam_member" "team" {
  for_each = local.team_role_memberships

  project = local.project_id
  role    = each.value.role
  member  = each.value.principal
}
