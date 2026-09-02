output "project_id" {
  description = "The GCP project ID containing the shared foundation."
  value       = local.project_id
}

output "project_number" {
  description = "The numeric identifier of the GCP project."
  value       = local.project_number
}

output "network_self_link" {
  description = "The self-link of the shared assessment VPC."
  value       = google_compute_network.assessment.self_link
}

output "cluster_networks" {
  description = "The regional subnet, secondary-range, and control-plane network contract for GKE."
  value = {
    for region, network in local.cluster_networks : region => merge(network, {
      subnetwork_name      = google_compute_subnetwork.cluster[region].name
      subnetwork_self_link = google_compute_subnetwork.cluster[region].self_link
      pod_range_name       = "pods"
      service_range_name   = "services"
    })
  }
}

output "global_ipv4_address" {
  description = "The reserved global external IPv4 address for Multi-cluster Ingress."
  value       = google_compute_global_address.ingress.address
}

output "global_address_name" {
  description = "The reserved global IPv4 address resource name."
  value       = google_compute_global_address.ingress.name
}

output "cloud_armor_policy_name" {
  description = "The Cloud Armor security policy name."
  value       = google_compute_security_policy.assessment.name
}

output "ssl_policy_name" {
  description = "The minimum-TLS-1.2 SSL policy name."
  value       = google_compute_ssl_policy.assessment.name
}

output "tls_certificate_name" {
  description = "The Google-managed certificate name when HTTPS is enabled, otherwise null."
  value       = var.enable_https ? google_compute_managed_ssl_certificate.assessment[0].name : null
}

output "bigquery_dataset_id" {
  description = "The dataset ID receiving partitioned assessment logs."
  value       = google_bigquery_dataset.assessment_logs.dataset_id
}

output "grafana_runtime_gsa_email" {
  description = "The Grafana runtime Google service account email."
  value       = google_service_account.grafana.email
}

output "app_a_runtime_gsa_email" {
  description = "The App A runtime Google service account email."
  value       = google_service_account.app_a.email
}

output "gke_node_gsa_email" {
  description = "The dedicated GKE Autopilot node service account email."
  value       = google_service_account.gke_nodes.email
}

output "app_a_secret_id" {
  description = "The App A Secret Manager container ID."
  value       = google_secret_manager_secret.app_a.secret_id
}

output "grafana_admin_secret_id" {
  description = "The Grafana administrator Secret Manager container ID."
  value       = google_secret_manager_secret.grafana_admin.secret_id
}
