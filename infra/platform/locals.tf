locals {
  foundation_outputs = data.terraform_remote_state.foundation.outputs

  foundation = {
    project_id              = tostring(local.foundation_outputs.project_id)
    project_number          = tostring(local.foundation_outputs.project_number)
    network_self_link       = tostring(local.foundation_outputs.network_self_link)
    global_ipv4_address     = tostring(local.foundation_outputs.global_ipv4_address)
    global_address_name     = tostring(local.foundation_outputs.global_address_name)
    cloud_armor_policy_name = tostring(local.foundation_outputs.cloud_armor_policy_name)
    ssl_policy_name         = tostring(local.foundation_outputs.ssl_policy_name)
    tls_certificate_name = (
      local.foundation_outputs.tls_certificate_name == null
      ? null
      : tostring(local.foundation_outputs.tls_certificate_name)
    )
    bigquery_dataset_id       = tostring(local.foundation_outputs.bigquery_dataset_id)
    grafana_runtime_gsa_email = tostring(local.foundation_outputs.grafana_runtime_gsa_email)
    app_a_runtime_gsa_email   = tostring(local.foundation_outputs.app_a_runtime_gsa_email)
    gke_node_gsa_email        = tostring(local.foundation_outputs.gke_node_gsa_email)
    app_a_secret_id           = tostring(local.foundation_outputs.app_a_secret_id)
    grafana_admin_secret_id   = tostring(local.foundation_outputs.grafana_admin_secret_id)
    cluster_networks = tomap({
      for location, network in local.foundation_outputs.cluster_networks : location => {
        subnet_cidr          = tostring(network.subnet_cidr)
        pod_cidr             = tostring(network.pod_cidr)
        service_cidr         = tostring(network.service_cidr)
        master_cidr          = tostring(network.master_cidr)
        subnetwork_name      = tostring(network.subnetwork_name)
        subnetwork_self_link = tostring(network.subnetwork_self_link)
        pod_range_name       = tostring(network.pod_range_name)
        service_range_name   = tostring(network.service_range_name)
      }
    })
  }

  project_id             = local.foundation.project_id
  workload_identity_pool = "${local.project_id}.svc.id.goog"

  cluster_configs = {
    us-central1 = merge(local.foundation.cluster_networks["us-central1"], {
      name     = "gke-assessment-us-central1"
      location = "us-central1"
    })
    us-east1 = merge(local.foundation.cluster_networks["us-east1"], {
      name     = "gke-assessment-us-east1"
      location = "us-east1"
    })
  }

  assessment_labels = {
    environment = "assessment"
    managed_by  = "terraform"
  }
}
