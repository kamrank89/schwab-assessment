# GKE Assessment Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build three account-free testable Terraform roots that bootstrap GitHub trust, create shared GCP foundations, and provision two private regional Autopilot clusters with Fleet MCI/MCS support.

**Architecture:** `bootstrap` permanently owns the state bucket, GitHub WIF provider, the single federated pipeline service account, and that account's project permissions. `foundation` owns APIs, network, edge/security, logging/BigQuery, secret containers, team IAM, and workload runtime identities; `platform` owns GKE clusters, Fleet memberships, and managed multi-cluster features. Kubernetes objects are excluded from Terraform.

**Tech Stack:** Terraform 1.15.9, hashicorp/google 7.42.0, native `terraform test` mock providers, TFLint 0.64.0, Trivy 0.72.0, Google Cloud APIs.

**Spec:** `docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md`

## Global Constraints

- No standalone credentialed `terraform plan`, `terraform apply`, import, state mutation, or GCP API mutation is run during implementation. Native mock tests may use `command = plan` without credentials.
- Use only the `hashicorp/google` provider at exact version `7.42.0`; do not add a Kubernetes provider.
- Set `required_version = "~> 1.15.0"`; the repository installer selects Terraform `1.15.9`.
- Commit `.terraform.lock.hcl` for Linux AMD64 and ARM64 after provider initialization.
- Use three state prefixes in one hardened bucket: `bootstrap`, `foundation`, and `platform`.
- Keep bootstrap resources after routine teardown; the state bucket has versioning, uniform access, public-access prevention, and `force_destroy = false`.
- Create exactly one GitHub-federated service account named `assessment-deployer`; no service-account key resource is allowed.
- Bind WIF trust to immutable GitHub owner and repository IDs, `refs/heads/main`, and `production-plan`, `production`, and `teardown` environment subjects.
- Use explicit predefined roles rather than primitive Owner or Editor roles.
- Keep Grafana and App A runtime Google service accounts separate from the GitHub deployer and grant only their runtime permissions.
- Use one custom VPC and non-overlapping regional subnet, Pod, Service, and `/28` control-plane ranges.
- Set cluster public IP endpoints disabled and use the IAM-aware DNS endpoint plus Fleet Connect Gateway.
- Enable Autopilot, VPC-native networking, Workload Identity Federation for GKE, managed Secret Manager CSI, workload/control-plane logging, system metrics, and Managed Service for Prometheus.
- Terraform outputs may contain identifiers and commands, never tokens, keys, kubeconfig content, secret values, or saved plan content.

---

## File Structure

```text
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
│   ├── terraform.tfvars.example
│   └── tests/bootstrap.tftest.hcl
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
│   ├── terraform.tfvars.example
│   └── tests/foundation.tftest.hcl
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
    ├── terraform.tfvars.example
    └── tests/platform.tftest.hcl
```

`backend.tf.example` is intentionally not loaded by Terraform during the first bootstrap apply. The future bootstrap script creates ignored `backend.generated.tf` only after the bucket exists, then runs `terraform init -migrate-state`. Foundation and platform commit partial `backend "gcs" {}` blocks and always receive bucket/prefix through `-backend-config`.

### Task 1: Terraform root contracts and repository guard test

**Files:**
- Create: all `versions.tf`, `providers.tf`, `backend.tf`, and `backend.tf.example` files listed above
- Create: `tests/repository/test_terraform_contract.py`
- Create: `.tflint.hcl`
- Modify later: `tools/versions.env`, `tools/checksums.sha256`

**Interfaces:**
- Consumes: no previous implementation.
- Produces: `terraform_root(path: Path) -> TerraformRoot` test helper expectations and three provider-initializable roots.

- [ ] **Step 1: Write the failing repository contract**

```python
from pathlib import Path


ROOTS = [Path("infra/bootstrap"), Path("infra/foundation"), Path("infra/platform")]


def test_all_roots_pin_one_google_provider_and_exclude_kubernetes():
    for root in ROOTS:
        text = "\n".join(path.read_text() for path in root.glob("*.tf"))
        assert 'required_version = "~> 1.15.0"' in text
        assert 'source  = "hashicorp/google"' in text
        assert 'version = "7.42.0"' in text
        assert "hashicorp/kubernetes" not in text
        assert 'provider "kubernetes"' not in text


def test_no_cloud_mutation_command_is_embedded_in_account_free_targets():
    makefile = Path("Makefile").read_text() if Path("Makefile").exists() else ""
    forbidden = ("terraform plan", "terraform apply", "gcloud services enable")
    assert not any(command in makefile for command in forbidden)
```

- [ ] **Step 2: Run the focused test and observe the missing-root failure**

Run: `python3 -m pytest tests/repository/test_terraform_contract.py -q`

Expected: FAIL because `versions.tf` and provider constraints do not exist.

- [ ] **Step 3: Add exact version/provider blocks**

Each root's `versions.tf` contains:

```hcl
terraform {
  required_version = "~> 1.15.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.42.0"
    }
  }
}
```

Each `providers.tf` contains `provider "google" { project = local.project_id }`; bootstrap uses `local.effective_project_id`. `foundation/backend.tf` and `platform/backend.tf` contain only:

```hcl
terraform {
  backend "gcs" {}
}
```

`infra/bootstrap/backend.tf.example` contains the same block and a comment identifying `infra/bootstrap/backend.generated.tf` as the runtime copy target. The generated file stays beside the other root-module files so Terraform loads it, while `.gitignore` excludes it.

- [ ] **Step 4: Initialize without a backend and lock the provider**

Run for each root after its variables/locals are syntactically present:

```bash
terraform -chdir=infra/bootstrap init -backend=false -input=false
terraform -chdir=infra/foundation init -backend=false -input=false
terraform -chdir=infra/platform init -backend=false -input=false
terraform -chdir=infra/bootstrap providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64
terraform -chdir=infra/foundation providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64
terraform -chdir=infra/platform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64
```

Expected: provider version `7.42.0` is selected and checksums are recorded independently in each root.

- [ ] **Step 5: Run formatting and the repository contract**

Run:

```bash
terraform fmt -check -recursive infra
python3 -m pytest tests/repository/test_terraform_contract.py -q
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add .tflint.hcl infra tests/repository/test_terraform_contract.py
git commit -m "build: establish Terraform root contracts"
```

### Task 2: Bootstrap state and the single GitHub federated identity

**Files:**
- Create: `infra/bootstrap/{variables,locals,project,state_bucket,wif,pipeline_iam,outputs}.tf`
- Create: `infra/bootstrap/terraform.tfvars.example`
- Create: `infra/bootstrap/tests/bootstrap.tftest.hcl`

**Interfaces:**
- Consumes variables: `project_id:string`, `create_project:bool`, `project_name:string`, `billing_account:string|null`, `folder_id:string|null`, `organization_id:string|null`, `state_bucket_name:string`, `state_bucket_location:string`, `github_repository:string`, `github_repository_id:string`, `github_owner_id:string`.
- Produces outputs: `effective_project_id:string`, `project_number:string`, `terraform_state_bucket:string`, `wif_provider_resource_name:string`, `pipeline_service_account_email:string`, `github_repository:string`, `allowed_environments:list(string)`.

- [ ] **Step 1: Write the failing native test**

```hcl
mock_provider "google" {}

variables {
  project_id            = "schwab-assessment-test"
  create_project        = false
  state_bucket_name     = "schwab-assessment-test-tfstate"
  github_repository     = "example/schwab-assessment"
  github_repository_id  = "123456789"
  github_owner_id       = "987654321"
}

override_data {
  target = data.google_project.current[0]
  values = { number = "112233445566" }
}

run "bootstrap_security_contract" {
  command = plan

  assert {
    condition     = google_storage_bucket.terraform_state.uniform_bucket_level_access && google_storage_bucket.terraform_state.public_access_prevention == "enforced" && google_storage_bucket.terraform_state.versioning[0].enabled && !google_storage_bucket.terraform_state.force_destroy
    error_message = "State bucket hardening changed."
  }

  assert {
    condition     = google_service_account.pipeline.account_id == "assessment-deployer"
    error_message = "Exactly one pipeline identity must retain the approved name."
  }

  assert {
    condition     = var.create_project ? !google_project.assessment[0].auto_create_network : true
    error_message = "New assessment projects must not retain a default network."
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.repository_id") && strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.repository_owner_id") && strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "refs/heads/main")
    error_message = "WIF must use immutable repository IDs and main."
  }

  assert {
    condition     = alltrue([for name in ["production-plan", "production", "teardown"] : strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, name)])
    error_message = "Every protected environment must be in the WIF condition."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.oidc[0].allowed_audiences == ["https://iam.googleapis.com/projects/112233445566/locations/global/workloadIdentityPools/github-actions/providers/github"]
    error_message = "The provider audience must exactly match the Google auth Action audience."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_mapping == local.github_attribute_mapping
    error_message = "The immutable GitHub claim mapping changed."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == local.github_attribute_condition
    error_message = "The WIF condition must equal the exact repository, owner, ref, and environment-subject contract."
  }

  assert {
    condition     = google_service_account_iam_member.pipeline_wif.member == "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/123456789"
    error_message = "WIF impersonation must be bound through the immutable repository-ID principal set."
  }
}
```

- [ ] **Step 2: Run it and prove resources are absent**

Run: `terraform -chdir=infra/bootstrap test -test-directory=tests -no-color`

Expected: FAIL with undeclared resource references.

- [ ] **Step 3: Implement validated inputs and project selection**

`variables.tf` rejects an empty project ID, non-numeric GitHub IDs, a repository not matching `^[^/]+/[^/]+$`, and invalid creation combinations. Project creation requires `billing_account` and permits zero or one non-null parent (`folder_id` or `organization_id`), never both; zero supports a personal/no-organization account and is recorded as a landing-zone limitation. Attachment requires no billing or parent mutation inputs. `project.tf` uses:

```hcl
resource "google_project" "assessment" {
  count               = var.create_project ? 1 : 0
  project_id          = var.project_id
  name                = var.project_name
  billing_account     = var.billing_account
  folder_id           = var.folder_id
  org_id              = var.organization_id
  auto_create_network = false
  deletion_policy     = "ABANDON"
}

data "google_project" "current" {
  count      = var.create_project ? 0 : 1
  project_id = var.project_id
}
```

`locals.tf` selects the created or attached ID/number and fixes `allowed_environments = ["production-plan", "production", "teardown"]`. New projects remove the default network through `auto_create_network = false`; attached projects are never modified destructively, and setup preflight reports any existing default network as an operator-owned governance item. Setup and the architecture overview distinguish the preferred folder/organization path from the supported no-organization assessment fallback.

- [ ] **Step 4: Implement state-bucket hardening**

```hcl
resource "google_storage_bucket" "terraform_state" {
  project                     = local.effective_project_id
  name                        = var.state_bucket_name
  location                    = var.state_bucket_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning { enabled = true }

  lifecycle_rule {
    condition { num_newer_versions = 10 }
    action { type = "Delete" }
  }
}
```

Add bucket-scoped `roles/storage.objectAdmin` and `roles/storage.legacyBucketReader` members for the pipeline service account; do not grant project-wide Storage Admin.

- [ ] **Step 5: Implement repository-scoped WIF**

Create pool `github-actions`, provider `github`, issuer `https://token.actions.githubusercontent.com`, and allowed audience `https://iam.googleapis.com/projects/${local.project_number}/locations/global/workloadIdentityPools/github-actions/providers/github`. This is the exact audience supplied to the pinned Google auth Action when `workload_identity_provider` is the provider's full `projects/...` name. Define the mapping and condition once as `local.github_attribute_mapping` and `local.github_attribute_condition`, then assign those locals directly to the provider so native tests can require exact equality. Use this mapping:

```hcl
attribute_mapping = {
  "google.subject"                = "assertion.sub"
  "attribute.actor_id"            = "assertion.actor_id"
  "attribute.repository_id"       = "assertion.repository_id"
  "attribute.repository_owner_id" = "assertion.repository_owner_id"
  "attribute.ref"                 = "assertion.ref"
}
```

The condition is the conjunction of exact immutable IDs and main, plus an exact-subject disjunction for the three environment names:

```text
assertion.repository_id == '${var.github_repository_id}' &&
assertion.repository_owner_id == '${var.github_owner_id}' &&
assertion.ref == 'refs/heads/main' &&
(assertion.sub == 'repo:${var.github_repository}:environment:production-plan' ||
 assertion.sub == 'repo:${var.github_repository}:environment:production' ||
 assertion.sub == 'repo:${var.github_repository}:environment:teardown')
```

The named `google_service_account_iam_member.pipeline_wif` resource grants `roles/iam.workloadIdentityUser` to `principalSet://iam.googleapis.com/${pool.name}/attribute.repository_id/${var.github_repository_id}`.

- [ ] **Step 6: Grant the explicit pipeline permission union**

`locals.pipeline_project_roles` is exactly:

```hcl
toset([
  "roles/bigquery.admin",
  "roles/compute.admin",
  "roles/container.admin",
  "roles/dns.admin",
  "roles/gkehub.admin",
  "roles/gkehub.gatewayAdmin",
  "roles/gkehub.viewer",
  "roles/iam.serviceAccountAdmin",
  "roles/logging.configWriter",
  "roles/monitoring.viewer",
  "roles/resourcemanager.projectIamAdmin",
  "roles/secretmanager.admin",
  "roles/serviceusage.serviceUsageAdmin",
])
```

Use `google_project_iam_member` keyed by the role. The role list is intentionally broad for one assessment identity, contains no Owner/Editor, and is owned only by bootstrap state so routine foundation teardown cannot delete its own caller.

Create `google_project_service.bootstrap` with `disable_on_destroy = false` for `cloudbilling.googleapis.com`, `cloudresourcemanager.googleapis.com`, `iam.googleapis.com`, `iamcredentials.googleapis.com`, `serviceusage.googleapis.com`, `storage.googleapis.com`, and `sts.googleapis.com`. The bucket, WIF pool/provider, and service account depend on the matching enabled services. For optional project creation, the human preflight separately verifies that Cloud Resource Manager and Cloud Billing APIs are usable in the ADC quota project before the target project exists; target-project service resources cannot solve that caller-side bootstrap dependency retroactively.

- [ ] **Step 7: Add safe outputs and examples**

Outputs contain identifiers only. `terraform.tfvars.example` uses syntactically valid non-secret examples such as repository ID `123456789` and explains that numeric IDs come from GitHub's API, not repository names.

- [ ] **Step 8: Verify and commit**

Run:

```bash
terraform -chdir=infra/bootstrap fmt -check
terraform -chdir=infra/bootstrap validate
terraform -chdir=infra/bootstrap test -test-directory=tests -no-color
python3 -m pytest tests/repository/test_terraform_contract.py -q
```

Expected: PASS with mock-provider execution and no credential lookup.

```bash
git add infra/bootstrap tests/repository/test_terraform_contract.py
git commit -m "feat: add keyless GitHub bootstrap infrastructure"
```

### Task 3: Shared network, edge, logging, secrets, and runtime IAM

**Files:**
- Create: all `infra/foundation/*.tf`, example variables, and `tests/foundation.tftest.hcl`
- Extend: `tests/repository/test_terraform_contract.py`

**Interfaces:**
- Consumes required non-secret `terraform_state_bucket:string` plus bootstrap remote-state outputs, or `bootstrap_outputs_override` with keys `effective_project_id`, `project_number`, `terraform_state_bucket`, and `pipeline_service_account_email`.
- Produces `project_id:string`, `project_number:string`, `network_self_link:string`, `cluster_networks:map(object)`, `global_ipv4_address:string`, `global_address_name:string`, `cloud_armor_policy_name:string`, `ssl_policy_name:string`, `tls_certificate_name:string|null`, `bigquery_dataset_id:string`, `grafana_runtime_gsa_email:string`, `app_a_runtime_gsa_email:string`, `gke_node_gsa_email:string`, and secret IDs.

- [ ] **Step 1: Write the failing foundation test**

Create a native mock test with `bootstrap_outputs_override` and assertions equivalent to:

```hcl
assert {
  condition = length(local.cluster_networks) == 2 &&
    contains(keys(local.cluster_networks), "us-central1") &&
    contains(keys(local.cluster_networks), "us-east1") &&
    length(distinct(flatten([for network in values(local.cluster_networks) : [network.subnet_cidr, network.pod_cidr, network.service_cidr, network.master_cidr]]))) == 8
  error_message = "Every regional primary/Pod/Service/control-plane CIDR must be unique."
}

assert {
  condition = alltrue([for subnet in google_compute_subnetwork.cluster :
    subnet.private_ip_google_access &&
    subnet.log_config[0].aggregation_interval == "INTERVAL_10_MIN" &&
    subnet.log_config[0].flow_sampling == 0.1
  ])
  error_message = "Private Google Access and bounded VPC Flow Logs are required in both regions."
}

assert {
  condition = google_logging_project_sink.bigquery.unique_writer_identity &&
    google_logging_project_sink.bigquery.bigquery_options[0].use_partitioned_tables &&
    alltrue([for token in ["k8s_container", "k8s_node", "k8s_control_plane_component", "http_load_balancer", "audited_resource"] : strcontains(google_logging_project_sink.bigquery.filter, token)])
  error_message = "The sink lost a required log class or partitioned tables."
}

assert {
  condition     = alltrue([for service in google_project_service.required : !service.disable_on_destroy])
  error_message = "Routine teardown must retain APIs for asynchronous cleanup and residual discovery."
}

assert {
  condition     = google_service_account.grafana.account_id == "grafana-runtime" && google_service_account.app_a.account_id == "app-a-runtime" && google_service_account.gke_nodes.account_id == "gke-autopilot-nodes"
  error_message = "Workload and node identities must be explicit and separate from the pipeline identity."
}

assert {
  condition     = google_project_iam_member.gke_node_role.role == "roles/container.defaultNodeServiceAccount" && google_service_account_iam_member.pipeline_node_act_as.role == "roles/iam.serviceAccountUser"
  error_message = "Autopilot nodes need their minimum role and the deployer needs scoped actAs."
}
```

- [ ] **Step 2: Run it and observe undeclared resources**

Run: `terraform -chdir=infra/foundation test -test-directory=tests -no-color`

Expected: FAIL before foundation resources exist.

- [ ] **Step 3: Implement remote-state override and fixed networks**

`remote_state.tf` reads GCS bucket `var.terraform_state_bucket` and prefix `bootstrap` only when `bootstrap_outputs_override == null`; tests inject the same typed object and a syntactically valid dummy bucket. The variable is required, non-empty, and is passed separately from backend initialization because `data.terraform_remote_state` cannot infer the backend's `-backend-config`. `local.cluster_networks` is exactly:

```hcl
{
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
```

Create a custom-mode global-routing VPC, one subnetwork per entry with Private Google Access, named `pods`/`services` secondary ranges, and sampled VPC Flow Logs (`INTERVAL_10_MIN`, flow sampling `0.1`, metadata `INCLUDE_ALL_METADATA`). Create one router/NAT per region; NAT covers all primary and secondary ranges and enables errors-only logging. Flow/NAT logs remain in Cloud Logging's normal retention but are excluded from the narrow rubric-focused BigQuery sink to bound ingestion cost.

- [ ] **Step 4: Enable the exact API set**

Create `google_project_service.required` from this set with `disable_on_destroy = false`:

```hcl
toset([
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
```

Resources explicitly depend on their corresponding service entries. Foundation deliberately does not re-declare `cloudbilling`, `cloudresourcemanager`, `iam`, `iamcredentials`, `serviceusage`, `storage`, or `sts`: bootstrap state already owns those prerequisite API resources, so routine foundation teardown cannot disable bootstrap trust or create cross-state ownership drift. Foundation APIs also remain enabled after routine teardown so asynchronous MCI cleanup and residual discovery can complete; enabled APIs alone do not create billable resources, and final project decommissioning is a separate administrator action.

- [ ] **Step 5: Implement edge and TLS staging**

Create a global external IPv4 address, a `MODERN` SSL policy named exactly `schwab-assessment-tls` with minimum TLS 1.2, and a Cloud Armor policy with:

- priority `1000`: per-IP throttle of 100 requests per 60 seconds, conform action `allow`, exceed action `deny(429)`;
- priority `2000`: SQL injection stable WAF sensitivity 2 in preview, action `deny(403)`;
- priority `2100`: XSS stable WAF sensitivity 2 in preview, action `deny(403)`;
- priority `2147483647`: default allow.

Require a validated non-empty `dns_name` hostname whenever either `enable_https` or `manage_dns` is true. If `enable_https` is true, create one global `google_compute_managed_ssl_certificate`. If `manage_dns` is true, require `dns_zone_name`; `create_dns_zone` selects whether Terraform creates that public zone or looks up an existing zone before creating the A record to the reserved address. Creating a zone additionally requires `dns_zone_dns_name`, a trailing-dot DNS suffix that contains `dns_name`; an existing zone gets its suffix from the data source and validation proves the hostname belongs to it. Reject `create_dns_zone = true` when `manage_dns = false`, and reject any hostname/zone mismatch before planning resources. Output the certificate name for the MCI pre-shared certificate annotation. Do not create a Kubernetes `ManagedCertificate`; MCI does not support its declarative generation.

- [ ] **Step 6: Implement partitioned log export**

Create dataset `assessment_logs` in `US` with labels, 30-day default partition expiration, and `delete_contents_on_destroy = true`. Create one project sink with destination `bigquery.googleapis.com/projects/${project_id}/datasets/${dataset_id}`, unique writer identity, partitioned tables, and this logical filter:

```text
resource.type=("k8s_container" OR "k8s_node" OR "k8s_control_plane_component" OR "k8s_cluster" OR "http_load_balancer")
OR (resource.type="audited_resource" AND protoPayload.serviceName="k8s.io")
```

Grant only the generated sink writer `roles/bigquery.dataEditor` on the dataset.

- [ ] **Step 7: Implement secret containers, runtime identities, and the node identity**

Create automatically replicated secret containers `app-a-demo` and `grafana-admin` with labels; create no versions or plaintext Terraform values. Create `app-a-runtime`, `grafana-runtime`, and `gke-autopilot-nodes` GSAs. Bind the workload GSAs to KSAs `assessment/app-a` and `observability/grafana` through `roles/iam.workloadIdentityUser`. Grant:

- App A: secret accessor only on `app-a-demo`.
- Grafana: secret accessor only on `grafana-admin`, project Monitoring Viewer, project BigQuery Job User, and dataset BigQuery Data Viewer. The current predefined Job User role already includes `resourcemanager.projects.get` and `resourcemanager.projects.list`, satisfying the plugin project selector without Browser or a custom role; repository tests document and assert this deliberate role reuse.
- GKE node identity: project `roles/container.defaultNodeServiceAccount` only. Grant the pipeline identity `roles/iam.serviceAccountUser` on this one node service account through a service-account-level IAM member so cluster creation has `iam.serviceAccounts.actAs` without a project-wide act-as grant.

No workload GSA receives a pipeline administration role.

- [ ] **Step 8: Implement optional team IAM**

Accept null or non-empty principal lists for Dev, Ops, and SRE. Use these exact reviewed project-role sets:

```hcl
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
```

The IAM matrix explains that Dev can work with Kubernetes objects but not clusters or project infrastructure, Ops can observe and manage alert policy without workload or infrastructure administration, and SRE has GKE operational administration plus read-only compute/Fleet context and monitoring administration. None can impersonate service accounts or read Secret Manager values from these grants, and Kubernetes RBAC remains a separate authorization layer. Use additive `google_project_iam_member` instances rather than authoritative `google_project_iam_policy` or `google_project_iam_binding` resources so organization-managed members are not removed. Native and repository tests require exact equality with this map and reject primitive roles, service-account impersonation roles, or secret-access roles in any team set.

Commit `assessment.auto.tfvars` as the reviewed non-secret deployment baseline: `enable_https = false`, `manage_dns = false`, `create_dns_zone = false`, nullable DNS hostname/zone resource/zone suffix values, and empty Dev/Ops/SRE principal lists. Environment `TF_VAR_*` values may override it for a reviewed DNS/TLS or team-IAM change; no manual source edit is required for the first HTTP deployment.

- [ ] **Step 9: Verify and commit**

Run:

```bash
terraform -chdir=infra/foundation fmt -check
terraform -chdir=infra/foundation validate
terraform -chdir=infra/foundation test -test-directory=tests -no-color
tflint --chdir=infra/foundation
trivy config --exit-code 1 --severity HIGH,CRITICAL infra/foundation
```

Expected: PASS with mock data and no GCP credential.

```bash
git add infra/foundation tests/repository/test_terraform_contract.py
git commit -m "feat: add shared GCP foundation"
```

### Task 4: Private regional Autopilot clusters and Fleet features

**Files:**
- Create: all `infra/platform/*.tf`, example variables, and `tests/platform.tftest.hcl`
- Extend: `tests/repository/test_terraform_contract.py`

**Interfaces:**
- Consumes required non-secret `terraform_state_bucket:string` plus foundation remote-state outputs, or `foundation_outputs_override` matching Task 3.
- Produces `clusters:map(object({name,location,fleet_membership_name}))`, `mci_config_membership_name:string`, `workload_identity_pool:string`, plus pass-through runtime identifiers and edge/logging outputs. It does not produce endpoint credentials.

- [ ] **Step 1: Write the failing native test**

```hcl
mock_provider "google" {}

run "autopilot_and_fleet_contract" {
  command = plan

  assert {
    condition     = length(google_container_cluster.regional) == 2 && alltrue([for cluster in values(google_container_cluster.regional) : cluster.enable_autopilot && cluster.networking_mode == "VPC_NATIVE"])
    error_message = "Exactly two VPC-native Autopilot clusters are required."
  }

  assert {
    condition = alltrue([for region, cluster in google_container_cluster.regional :
      cluster.private_cluster_config[0].enable_private_nodes &&
      cluster.private_cluster_config[0].master_ipv4_cidr_block == local.cluster_networks[region].master_cidr &&
      !cluster.control_plane_endpoints_config[0].ip_endpoints_config[0].enabled &&
      cluster.control_plane_endpoints_config[0].dns_endpoint_config[0].allow_external_traffic
    ])
    error_message = "Control planes must use private nodes and the IAM-aware DNS endpoint, not public IP endpoints."
  }

  assert {
    condition     = google_gke_hub_feature.multicluster_ingress.location == "global" && google_gke_hub_feature.multicluster_service_discovery.location == "global" && google_gke_hub_feature.multicluster_ingress.spec[0].multiclusteringress[0].config_membership == google_gke_hub_membership.cluster["us-central1"].id
    error_message = "us-central1 must remain the MCI configuration membership."
  }

  assert {
    condition = google_container_cluster.regional["us-central1"].name == "gke-assessment-us-central1" &&
      google_container_cluster.regional["us-east1"].name == "gke-assessment-us-east1" &&
      google_gke_hub_membership.cluster["us-central1"].membership_id == "gke-assessment-us-central1" &&
      google_gke_hub_membership.cluster["us-east1"].membership_id == "gke-assessment-us-east1" &&
      alltrue([for membership in values(google_gke_hub_membership.cluster) : membership.location == "global"])
    error_message = "Cluster and global membership names must match the committed MCS and gateway contracts."
  }
}
```

- [ ] **Step 2: Run it and observe missing cluster resources**

Run: `terraform -chdir=infra/platform test -test-directory=tests -no-color`

Expected: FAIL with undeclared cluster and Fleet resources.

- [ ] **Step 3: Implement typed foundation-state consumption**

Use the same nullable override pattern as foundation. Production reads GCS bucket `var.terraform_state_bucket` and prefix `foundation`; tests provide a dummy bucket and supply project, VPC, range names/self-links, GSAs including the GKE node identity, global IP/name, Cloud Armor name, SSL policy/certificate names, dataset, and secret IDs. Platform never repeats or independently invents those values. Every deployment command passes the same `TF_STATE_BUCKET` both to backend initialization and as `TF_VAR_terraform_state_bucket`.

- [ ] **Step 4: Implement the two regional clusters**

Create `google_container_cluster.regional` over only `us-central1` and `us-east1` with:

```hcl
enable_autopilot    = true
location            = each.key
networking_mode     = "VPC_NATIVE"
deletion_protection = false

release_channel { channel = "REGULAR" }

private_cluster_config {
  enable_private_nodes    = true
  master_ipv4_cidr_block = local.cluster_networks[each.key].master_cidr
}

control_plane_endpoints_config {
  dns_endpoint_config {
    allow_external_traffic    = true
    enable_k8s_tokens_via_dns = false
    enable_k8s_certs_via_dns  = false
  }
  ip_endpoints_config { enabled = false }
}

workload_identity_config {
  workload_pool = "${local.project_id}.svc.id.goog"
}

cluster_autoscaling {
  auto_provisioning_defaults {
    service_account = local.gke_node_gsa_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}
```

Set cluster and Fleet membership names exactly to `gke-assessment-us-central1` and `gke-assessment-us-east1`; those names are a tested contract with the MCS links. Use the exact VPC/subnet and secondary range names from foundation and the dedicated Autopilot node GSA. Enable the Secret Manager managed component with rotation enabled at `300s`, `SYSTEM_COMPONENTS`, `WORKLOADS`, `APISERVER`, `SCHEDULER`, and `CONTROLLER_MANAGER` logs, system/component metrics, and managed Prometheus. Set a maintenance window and labels identifying environment, owner, and assessment.

- [ ] **Step 5: Register both clusters and enable MCS/MCI**

Create one regular `google_gke_hub_membership` per cluster using its resource link, with membership location explicitly fixed to `global`. Create globally located feature `multiclusterservicediscovery`, then globally located feature `multiclusteringress` with the full `us-central1` membership ID as configuration membership. MCI explicitly depends on both memberships and MCS. Do not create any Kubernetes traffic resource here.

- [ ] **Step 6: Restrict outputs and add connect commands**

Output cluster names/locations/membership names and a map of non-secret command templates:

```text
gcloud container fleet memberships get-credentials ${membership_name} --project ${project_id}
```

Do not output `google_container_cluster.*.endpoint`, master auth, access tokens, certificates, or kubeconfig content. Extend the Python repository test to reject those output tokens.

- [ ] **Step 7: Verify and commit**

Run:

```bash
terraform -chdir=infra/platform fmt -check
terraform -chdir=infra/platform validate
terraform -chdir=infra/platform test -test-directory=tests -no-color
tflint --chdir=infra/platform
trivy config --exit-code 1 --severity HIGH,CRITICAL infra/platform
python3 -m pytest tests/repository/test_terraform_contract.py -q
```

Expected: PASS with no cloud calls.

```bash
git add infra/platform tests/repository/test_terraform_contract.py
git commit -m "feat: add private Autopilot Fleet platform"
```

### Task 5: Cross-state and teardown-order policy gate

**Files:**
- Create: `policy/terraform.rego`
- Extend: `tests/repository/test_terraform_contract.py`
- Document later: `docs/architecture/terraform-state-boundaries.md`, `docs/setup/teardown.md`

**Interfaces:**
- Consumes: all Terraform roots.
- Produces: a machine-enforced ownership matrix and reverse dependency order `workloads -> platform -> foundation`; bootstrap is excluded from routine teardown.

- [ ] **Step 1: Add failing ownership tests**

```python
def test_terraform_does_not_own_kubernetes_objects():
    text = "\n".join(path.read_text() for path in Path("infra").rglob("*.tf"))
    forbidden = ("kubernetes_", "kubectl_manifest", "helm_release", "ManagedCertificate")
    assert not any(token in text for token in forbidden)


def test_pipeline_iam_has_one_state_owner():
    bootstrap = "\n".join(path.read_text() for path in Path("infra/bootstrap").glob("*.tf"))
    other = "\n".join(path.read_text() for path in Path("infra").rglob("*.tf") if "bootstrap" not in path.parts)
    assert "assessment-deployer" in bootstrap
    assert "assessment-deployer" not in other


def test_project_service_ownership_is_disjoint_between_states():
    bootstrap = project_services(Path("infra/bootstrap"))
    foundation = project_services(Path("infra/foundation"))
    assert bootstrap.isdisjoint(foundation)
    assert {"cloudbilling.googleapis.com", "serviceusage.googleapis.com", "sts.googleapis.com"} <= bootstrap
```

Run: `python3 -m pytest tests/repository/test_terraform_contract.py -q`

Expected: FAIL until ownership rules and policy are complete.

- [ ] **Step 2: Add Rego invariants**

The policy rejects public-access state buckets, non-Autopilot clusters, enabled control-plane IP endpoints, primitive project roles, service-account keys, and BigQuery sinks without partitioned tables. Every denial message names the Terraform address and violated invariant.

- [ ] **Step 3: Run the complete infrastructure gate**

```bash
make test-terraform
```

Expected: all three init/validate/test runs, TFLint, Trivy, Rego, and Python contracts pass. Native `terraform test` may execute its declared mock-provider `command = plan` runs; the transcript must contain no standalone or credentialed `terraform plan`, no `terraform apply`, and no ADC lookup.

- [ ] **Step 4: Commit**

```bash
git add policy/terraform.rego tests/repository/test_terraform_contract.py
git commit -m "test: enforce Terraform ownership and security boundaries"
```

## Live-Only Boundary

These account-free tests prove HCL syntax, provider schema compatibility, declared dependency structure, and explicit configuration invariants. They do not prove credentials, IAM propagation, organization policy compatibility, service quota, state locking, resource creation, Fleet registration, Connect Gateway authorization, MCI reconciliation, certificate activation, log ingestion, BigQuery table creation, or destroy completion. The future deployment and evidence workflows own those assertions.
