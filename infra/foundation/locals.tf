locals {
  bootstrap_outputs = data.terraform_remote_state.bootstrap.outputs
  project_id        = local.bootstrap_outputs.effective_project_id
  project_number    = local.bootstrap_outputs.project_number

  cluster_networks = {
    us-central1 = {
      subnet_cidr  = "10.10.0.0/20"
      pod_cidr     = "10.20.0.0/16"
      service_cidr = "10.30.0.0/20"
      master_cidr  = "172.16.0.0/28"
    }
    us-east1 = {
      subnet_cidr  = "10.11.0.0/20"
      pod_cidr     = "10.21.0.0/16"
      service_cidr = "10.31.0.0/20"
      master_cidr  = "172.16.1.0/28"
    }
  }

  required_services = toset([
    "bigquery.googleapis.com",
    "clouderrorreporting.googleapis.com",
    "cloudprofiler.googleapis.com",
    "cloudtrace.googleapis.com",
    "compute.googleapis.com",
    "connectgateway.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "gkeconnect.googleapis.com",
    "gkehub.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "multiclusteringress.googleapis.com",
    "multiclusterservicediscovery.googleapis.com",
    "secretmanager.googleapis.com",
    "trafficdirector.googleapis.com",
  ])

  team_roles = {
    dev = [
      "roles/container.developer",
      "roles/logging.viewer",
      "roles/monitoring.viewer",
    ]
    ops = [
      "roles/container.viewer",
      "roles/logging.viewer",
      "roles/monitoring.alertPolicyEditor",
      "roles/monitoring.viewer",
    ]
    sre = [
      "roles/compute.viewer",
      "roles/container.admin",
      "roles/gkehub.viewer",
      "roles/logging.viewer",
      "roles/monitoring.admin",
    ]
  }

  team_principals = {
    dev = coalesce(var.dev_principals, [])
    ops = coalesce(var.ops_principals, [])
    sre = coalesce(var.sre_principals, [])
  }

  team_role_memberships = {
    for membership in flatten([
      for team, roles in local.team_roles : [
        for pair in setproduct(roles, local.team_principals[team]) : {
          team      = team
          role      = pair[0]
          principal = pair[1]
        }
      ]
    ]) : "${membership.team}|${membership.role}|${membership.principal}" => membership
  }

  normalized_dns_name = var.dns_name == null ? null : "${trimsuffix(lower(trimspace(var.dns_name)), ".")}."
}
