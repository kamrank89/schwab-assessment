output "clusters" {
  description = "The safe regional cluster and Fleet membership interface for workload deployment."
  value = {
    for location, cluster in google_container_cluster.assessment : location => {
      name                  = cluster.name
      location              = cluster.location
      fleet_membership_name = google_gke_hub_membership.assessment[location].membership_id
    }
  }
}

output "mci_config_membership_name" {
  description = "The fully qualified us-central1 Fleet membership selected for Multi-cluster Ingress configuration."
  value       = google_gke_hub_membership.assessment["us-central1"].id
}

output "workload_identity_pool" {
  description = "The GKE Workload Identity pool shared by both clusters."
  value       = local.workload_identity_pool
}

output "global_ipv4_address" {
  description = "The reserved global external IPv4 address for Multi-cluster Ingress."
  value       = local.foundation.global_ipv4_address
}

output "global_address_name" {
  description = "The reserved global IPv4 address resource name."
  value       = local.foundation.global_address_name
}

output "cloud_armor_policy_name" {
  description = "The Cloud Armor security policy name."
  value       = local.foundation.cloud_armor_policy_name
}

output "ssl_policy_name" {
  description = "The minimum-TLS-1.2 SSL policy name."
  value       = local.foundation.ssl_policy_name
}

output "tls_certificate_name" {
  description = "The Google-managed certificate name when HTTPS is enabled, otherwise null."
  value       = local.foundation.tls_certificate_name
}

output "bigquery_dataset_id" {
  description = "The dataset ID receiving partitioned assessment logs."
  value       = local.foundation.bigquery_dataset_id
}

output "grafana_runtime_gsa_email" {
  description = "The Grafana runtime Google service account email."
  value       = local.foundation.grafana_runtime_gsa_email
}

output "app_a_runtime_gsa_email" {
  description = "The App A runtime Google service account email."
  value       = local.foundation.app_a_runtime_gsa_email
}

output "gke_node_gsa_email" {
  description = "The dedicated GKE Autopilot node service account email."
  value       = local.foundation.gke_node_gsa_email
}

output "app_a_secret_id" {
  description = "The App A Secret Manager container ID."
  value       = local.foundation.app_a_secret_id
}

output "grafana_admin_secret_id" {
  description = "The Grafana administrator Secret Manager container ID."
  value       = local.foundation.grafana_admin_secret_id
}

output "cluster_admin_email" {
  description = "The Google user email authorized for permanent cluster administration."
  value       = local.foundation.cluster_admin_email
}

output "fleet_get_credentials_commands" {
  description = "Connect Gateway credential command templates for the Fleet memberships."
  value = {
    for location, membership in google_gke_hub_membership.assessment : location =>
    "gcloud container fleet memberships get-credentials ${membership.membership_id} --project ${local.project_id}"
  }
}
