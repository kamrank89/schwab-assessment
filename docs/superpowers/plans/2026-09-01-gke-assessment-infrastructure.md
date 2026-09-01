# GKE Assessment Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build three Terraform roots that bootstrap GitHub trust, create shared GCP foundations, and provision two private regional Autopilot clusters with Fleet MCI/MCS support.

**Architecture:** bootstrap owns the state backend, GitHub WIF, and one pipeline identity. foundation owns APIs, networking, security, observability, secrets, and runtime identities; platform consumes its outputs to create GKE, Fleet, MCS, and MCI. Kubernetes objects remain Kustomize-owned and outside Terraform.

**Tech Stack:** Terraform 1.15.9, hashicorp/google 7.42.0, Google Cloud APIs.

**Spec:** docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md

## Global Constraints

- Do not deploy, run terraform plan, run terraform apply, import, mutate state, or call GCP APIs during implementation.
- Use only hashicorp/google at exact version 7.42.0; do not add a Kubernetes provider or Terraform-managed Kubernetes objects. Set required_version = "~> 1.15.0" and commit lock files for Linux AMD64 and ARM64.
- Use one hardened state bucket with bootstrap, foundation, and platform prefixes. Preserve versioning, uniform access, public-access prevention, and force_destroy = false.
- Create exactly one GitHub-federated assessment-deployer service account and no service-account key. WIF binds immutable owner/repository IDs and the exact `refs/heads/main` subject. Protected GitHub Environments are a documented production hardening option, not a baseline trust dependency.
- Use explicit predefined roles, never Owner or Editor. Keep Grafana and App A runtime identities separate from the deployer.
- Preserve the approved custom VPC, CIDRs, private/DNS-only control planes, Autopilot, VPC-native networking, GKE Workload Identity, Secret Manager CSI, logging, system metrics, Managed Prometheus, Fleet MCI/MCS, and output interfaces.
- Outputs contain identifiers and command templates only: never keys, tokens, kubeconfig content, secret values, endpoints, certificates, or saved plans.
- Account-free Terraform checks are only terraform fmt -check, init -backend=false, and terraform validate. Do not add Python, pytest, Rego, custom repository contracts/policy gates, or Python-backed helper installation.

---

## File Structure

~~~text
infra/
├── bootstrap/
│   ├── backend.tf.example
│   ├── versions.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── project.tf
│   ├── services.tf
│   ├── state_bucket.tf
│   ├── wif.tf
│   ├── pipeline_iam.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── foundation/
│   ├── backend.tf
│   ├── versions.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── remote_state.tf
│   ├── locals.tf
│   ├── apis.tf
│   ├── network.tf
│   ├── nat.tf
│   ├── ingress.tf
│   ├── dns.tf
│   ├── armor.tf
│   ├── logging_bigquery.tf
│   ├── secrets.tf
│   ├── workload_iam.tf
│   ├── team_iam.tf
│   ├── outputs.tf
│   ├── assessment.auto.tfvars
│   └── terraform.tfvars.example
└── platform/
    ├── backend.tf
    ├── versions.tf
    ├── providers.tf
    ├── variables.tf
    ├── remote_state.tf
    ├── locals.tf
    ├── clusters.tf
    ├── fleet.tf
    ├── multicluster_features.tf
    ├── outputs.tf
    └── terraform.tfvars.example
~~~

infra/bootstrap/backend.tf.example is not loaded during first bootstrap. The documented workflow creates ignored infra/bootstrap/backend.generated.tf after the bucket exists, then runs terraform init -migrate-state. Foundation and platform use partial backend "gcs" {} blocks and receive bucket/prefix through -backend-config.

### Task 1: Establish Terraform root conventions

**Files:**
- Create: infra/bootstrap/{backend.tf.example,versions.tf,providers.tf}
- Create: infra/foundation/{backend.tf,versions.tf,providers.tf}
- Create: infra/platform/{backend.tf,versions.tf,providers.tf}

**Interfaces:**
- Consumes: no state or credentials.
- Produces: three Google-provider roots with offline-initializable backends.

- [ ] **Step 1: Add version/provider blocks**

Each versions.tf contains:

~~~hcl
terraform {
  required_version = "~> 1.15.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.42.0"
    }
  }
}
~~~

Each providers.tf declares only provider "google"; bootstrap uses local.effective_project_id, foundation/platform use local.project_id.

- [ ] **Step 2: Add backend placeholders**

foundation/backend.tf and platform/backend.tf contain:

~~~hcl
terraform {
  backend "gcs" {}
}
~~~

Put the same block plus a backend.generated.tf comment in bootstrap/backend.tf.example.

- [ ] **Step 3: Initialize, lock, format, and commit**

~~~bash
terraform -chdir=infra/bootstrap init -backend=false -input=false
terraform -chdir=infra/foundation init -backend=false -input=false
terraform -chdir=infra/platform init -backend=false -input=false
terraform -chdir=infra/bootstrap providers lock -platform=linux_amd64 -platform=linux_arm64
terraform -chdir=infra/foundation providers lock -platform=linux_amd64 -platform=linux_arm64
terraform -chdir=infra/platform providers lock -platform=linux_amd64 -platform=linux_arm64
terraform fmt -check -recursive infra
git add infra/bootstrap infra/foundation infra/platform
git commit -m "build: establish Terraform root conventions"
~~~

Expected: Google 7.42.0 and both Linux checksums are recorded per root; formatting passes.

### Task 2: Bootstrap state and GitHub federated identity

**Files:**
- Create: infra/bootstrap/{variables.tf,locals.tf,project.tf,services.tf,state_bucket.tf,wif.tf,pipeline_iam.tf,outputs.tf,terraform.tfvars.example}

**Interfaces:**
- Consumes: project_id:string, create_project:bool, project_name:string, billing_account:string|null, folder_id:string|null, organization_id:string|null, state_bucket_name:string, state_bucket_location:string, github_repository:string, github_repository_id:string, github_owner_id:string.
- Produces: effective_project_id:string, project_number:string, terraform_state_bucket:string, wif_provider_resource_name:string, pipeline_service_account_email:string, github_repository:string, allowed_subject:string.

- [ ] **Step 1: Implement validated project selection and durable state**

Validate non-empty project/bucket IDs, numeric GitHub IDs, and github_repository with ^[^/]+/[^/]+$. A new project requires billing, allows at most one folder/organization parent, uses auto_create_network = false and deletion_policy = "ABANDON"; attachment never mutates creation-only billing/parent inputs. Derive `allowed_subject` exactly as `repo:<OWNER/REPO>:ref:refs/heads/main`.

Create the versioned, uniform-access, public-access-prevented state bucket with force_destroy = false and a ten-newer-version lifecycle rule. Grant the pipeline identity only bucket-scoped roles/storage.objectAdmin and roles/storage.legacyBucketReader.

- [ ] **Step 2: Implement bootstrap API ownership, WIF, and deployer IAM**

Own cloudbilling.googleapis.com, cloudresourcemanager.googleapis.com, iam.googleapis.com, iamcredentials.googleapis.com, serviceusage.googleapis.com, storage.googleapis.com, and sts.googleapis.com with disable_on_destroy = false.

Create pool github-actions, provider github, issuer https://token.actions.githubusercontent.com, and the Google auth Action audience containing the effective project number. Map google.subject, actor_id, repository_id, repository_owner_id, and ref from the matching immutable GitHub assertions. The attribute condition exactly checks immutable repository/owner IDs plus `assertion.sub == "repo:<OWNER/REPO>:ref:refs/heads/main"`; do not accept an Environment subject in the baseline. Create only assessment-deployer and bind WIF through its immutable repository-ID principal set.

Grant this exact predefined-role union:

~~~hcl
toset([
  "roles/bigquery.admin", "roles/compute.admin", "roles/container.admin",
  "roles/dns.admin", "roles/gkehub.admin", "roles/gkehub.gatewayAdmin",
  "roles/gkehub.viewer", "roles/iam.serviceAccountAdmin",
  "roles/logging.configWriter", "roles/monitoring.viewer",
  "roles/resourcemanager.projectIamAdmin", "roles/secretmanager.admin",
  "roles/serviceusage.serviceUsageAdmin",
])
~~~

- [ ] **Step 3: Add safe outputs and commit**

Export only the Task 2 interface; examples are valid non-secret values.

~~~bash
terraform fmt -check -recursive infra/bootstrap
terraform -chdir=infra/bootstrap init -backend=false -input=false
terraform -chdir=infra/bootstrap validate
git add infra/bootstrap
git commit -m "feat: add keyless GitHub bootstrap infrastructure"
~~~

### Task 3: Build shared GCP foundation

**Files:**
- Create: infra/foundation/{variables.tf,remote_state.tf,locals.tf,apis.tf,network.tf,nat.tf,ingress.tf,dns.tf,armor.tf,logging_bigquery.tf,secrets.tf,workload_iam.tf,team_iam.tf,outputs.tf,assessment.auto.tfvars,terraform.tfvars.example}

**Interfaces:**
- Consumes: terraform_state_bucket:string and bootstrap remote-state outputs containing effective_project_id, project_number, terraform_state_bucket, and pipeline_service_account_email.
- Produces: project_id:string, project_number:string, network_self_link:string, cluster_networks:map(object), global_ipv4_address:string, global_address_name:string, cloud_armor_policy_name:string, ssl_policy_name:string, tls_certificate_name:string|null, bigquery_dataset_id:string, grafana_runtime_gsa_email:string, app_a_runtime_gsa_email:string, gke_node_gsa_email:string, and secret IDs.

- [ ] **Step 1: Consume bootstrap state and implement exact networking**

Read GCS prefix bootstrap and require the state bucket as a non-secret input. Use exactly:

~~~hcl
{
  us-central1 = { subnet_cidr = "10.10.0.0/20", pod_cidr = "10.20.0.0/16", service_cidr = "10.30.0.0/20", master_cidr = "172.16.0.0/28" }
  us-east1    = { subnet_cidr = "10.11.0.0/20", pod_cidr = "10.21.0.0/16", service_cidr = "10.31.0.0/20", master_cidr = "172.16.1.0/28" }
}
~~~

Create the custom-mode global-routing VPC, regional subnets with pods/services ranges, Private Google Access, and Flow Logs INTERVAL_10_MIN/0.1/INCLUDE_ALL_METADATA; create one router/NAT per region covering primary and secondary ranges with errors-only NAT logging.

- [ ] **Step 2: Implement APIs, edge, logs, secrets, and IAM**

Own with disable_on_destroy = false: BigQuery, Error Reporting, Profiler, Trace, Compute, Connect Gateway, Container, DNS, GKE Connect/Hub, Logging, Monitoring, MCI, MCS, Secret Manager, and Traffic Director APIs. Do not duplicate bootstrap API ownership.

Reserve the global IPv4 address; create schwab-assessment-tls (MODERN, TLS 1.2); create Cloud Armor priority 1000 IP throttle (100/60s, deny 429), 2000 SQLi preview sensitivity 2, 2100 XSS preview sensitivity 2 (both deny 403), and 2147483647 default allow. Preserve validated DNS/TLS inputs and create a Compute managed certificate only when HTTPS is enabled; output its nullable name for MCI, never a Kubernetes ManagedCertificate.

Create US assessment_logs with 30-day partition expiration and a unique-writer partitioned sink covering k8s_container, k8s_node, k8s_control_plane_component, k8s_cluster, http_load_balancer, and relevant audits. Create empty replicated app-a-demo/grafana-admin secret containers; no values. Create app-a-runtime, grafana-runtime, gke-autopilot-nodes; bind App A to assessment/app-a, Grafana to observability/grafana, and grant only approved secret, Monitoring/BigQuery, node-default-role, and deployer scoped node actAs permissions.

Use additive optional team memberships only:

~~~hcl
team_roles = {
  dev = ["roles/container.developer", "roles/logging.viewer", "roles/monitoring.viewer"]
  ops = ["roles/container.viewer", "roles/logging.viewer", "roles/monitoring.alertPolicyEditor", "roles/monitoring.viewer"]
  sre = ["roles/compute.viewer", "roles/container.admin", "roles/gkehub.viewer", "roles/logging.viewer", "roles/monitoring.admin"]
}
~~~

Commit HTTP-first assessment.auto.tfvars: HTTPS/DNS flags false, nullable DNS values, empty team lists.

- [ ] **Step 3: Verify and commit**

~~~bash
terraform fmt -check -recursive infra/foundation
terraform -chdir=infra/foundation init -backend=false -input=false
terraform -chdir=infra/foundation validate
git add infra/foundation
git commit -m "feat: add shared GCP foundation"
~~~

### Task 4: Create the private Autopilot Fleet platform

**Files:**
- Create: infra/platform/{variables.tf,remote_state.tf,locals.tf,clusters.tf,fleet.tf,multicluster_features.tf,outputs.tf,terraform.tfvars.example}

**Interfaces:**
- Consumes: terraform_state_bucket:string and foundation remote-state outputs containing the Task 3 interface.
- Produces: clusters:map(object({name,location,fleet_membership_name})), mci_config_membership_name:string, workload_identity_pool:string, plus non-secret foundation runtime/edge/logging pass-through outputs; no endpoint, token, certificate, or kubeconfig output.

- [ ] **Step 1: Implement typed state consumption and two clusters**

Read GCS prefix foundation using the required non-secret state-bucket input. Create exactly gke-assessment-us-central1 and gke-assessment-us-east1: Autopilot, VPC-native, approved VPC/subnet/ranges and control-plane ranges, Regular channel, deletion_protection = false, private nodes, disabled IP endpoints, and external IAM-aware DNS access without tokens/certs via DNS.

Set the project svc.id.goog workload pool, node GSA, Secret Manager CSI rotation 300s, SYSTEM_COMPONENTS, WORKLOADS, APISERVER, SCHEDULER, and CONTROLLER_MANAGER logging, system/component metrics, Managed Prometheus, maintenance window, and assessment labels.

- [ ] **Step 2: Register Fleet, MCS, and MCI**

Create regular global memberships whose IDs exactly match cluster names. Enable globally located MCS, then globally located MCI. MCI uses the full us-central1 membership ID as its configuration membership and depends on both memberships and MCS. Terraform creates no Kubernetes traffic object; Kustomize owns explicit-membership MCS, MultiClusterService, MultiClusterIngress, BackendConfig, and FrontendConfig.

- [ ] **Step 3: Add safe outputs and commit**

Export the Task 4 interface and only command templates of the form gcloud container fleet memberships get-credentials <membership-name> --project <project-id>.

~~~bash
terraform fmt -check -recursive infra/platform
terraform -chdir=infra/platform init -backend=false -input=false
terraform -chdir=infra/platform validate
git add infra/platform
git commit -m "feat: add private Autopilot Fleet platform"
~~~

### Task 5: Run the infrastructure validation set

**Files:**
- Modify: no additional files.

**Interfaces:**
- Consumes: three Terraform roots.
- Produces: repeatable account-free Terraform validation without bespoke tooling.

- [ ] **Step 1: Run standard Terraform checks**

~~~bash
terraform fmt -check -recursive infra
terraform -chdir=infra/bootstrap init -backend=false -input=false
terraform -chdir=infra/bootstrap validate
terraform -chdir=infra/foundation init -backend=false -input=false
terraform -chdir=infra/foundation validate
terraform -chdir=infra/platform init -backend=false -input=false
terraform -chdir=infra/platform validate
~~~

- [ ] **Step 2: Confirm limits and clean state**

Expected: PASS with no backend access, credential lookup, Python runtime, or GCP call. These checks prove formatting and HCL/schema validity—not IAM propagation, quotas, state locking, resource creation, Fleet/MCI reconciliation, certificate activation, log ingestion, Connect Gateway authorization, workload rollout, required three ready replicas, or teardown completion. Those are deployment evidence.

~~~bash
git status --short
git log --oneline -5
~~~

Expected: no uncommitted infrastructure change remains; Tasks 1-4 produced the reviewed Terraform commits.

## Cross-Plan Interfaces to Preserve

- The deployment/Kustomize plan consumes clusters, mci_config_membership_name, workload_identity_pool, global_ipv4_address, global_address_name, cloud_armor_policy_name, ssl_policy_name, tls_certificate_name, grafana_runtime_gsa_email, app_a_runtime_gsa_email, and secret IDs. It retains replicas: 3 and minReplicas: 3 for App A and App B in both clusters.
- Kustomize owns Deployments, Services, RBAC, MCS, MCI, BackendConfig, FrontendConfig, and overlays. MCS explicitly selects gke-assessment-us-central1 and gke-assessment-us-east1; MCI uses the us-central1 configuration membership and Terraform address/Armor/TLS outputs.
- Deployment/teardown workflows consume bootstrap WIF provider, pipeline SA email, bucket, state prefixes, and command templates. They alone run credentialed plan/apply/deployment/evidence actions; bootstrap remains outside routine teardown.
