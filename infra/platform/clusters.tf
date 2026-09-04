resource "google_container_cluster" "assessment" {
  for_each = local.cluster_configs

  project  = local.project_id
  name     = each.value.name
  location = each.value.location

  description         = "Private regional Autopilot cluster for the GKE assessment"
  enable_autopilot    = true
  deletion_protection = false
  networking_mode     = "VPC_NATIVE"
  network             = local.foundation.network_self_link
  subnetwork          = each.value.subnetwork_self_link

  resource_labels = local.assessment_labels

  ip_allocation_policy {
    cluster_secondary_range_name  = each.value.pod_range_name
    services_secondary_range_name = each.value.service_range_name
  }

  private_cluster_config {
    enable_private_nodes   = true
    master_ipv4_cidr_block = each.value.master_cidr
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic    = true
      enable_k8s_tokens_via_dns = false
      enable_k8s_certs_via_dns  = false
    }

    ip_endpoints_config {
      enabled = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = local.workload_identity_pool
  }

  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = local.foundation.gke_node_gsa_email
    }
  }

  secret_manager_config {
    enabled = true

    rotation_config {
      enabled           = true
      rotation_interval = "300s"
    }
  }

  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
      "APISERVER",
      "SCHEDULER",
      "CONTROLLER_MANAGER",
    ]
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "APISERVER",
      "SCHEDULER",
      "CONTROLLER_MANAGER",
    ]

    managed_prometheus {
      enabled = true
    }
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T05:00:00Z"
      end_time   = "2026-01-03T09:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA"
    }
  }
}
