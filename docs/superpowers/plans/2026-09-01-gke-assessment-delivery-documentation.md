# GKE Assessment Delivery and Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the approved GKE assessment implementation deploy-ready after a one-time human OIDC/WIF bootstrap, with standard credential-free validation, manual deployment/teardown workflows, safe operational scripts, and complete honest documentation.

**Architecture:** Terraform owns GCP bootstrap, foundation, and platform resources; Kustomize owns Kubernetes manifests and the two regional overlays. Small Bash scripts supply operator entry points and guards, Make groups standard commands, and GitHub Actions runs credential-free validation plus manually dispatched deployment and teardown using a single OIDC-federated `assessment-deployer` identity. Repository development does not deploy anything.

**Tech Stack:** Terraform, Terraform tests, TFLint, Trivy, Kustomize, Kubeconform, yq, jq, Bash, ShellCheck, actionlint, Make, Google Cloud CLI 582.0.0, GitHub Actions, GitHub OIDC/Google Cloud Workload Identity Federation.

**Spec:** `docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md`

## Global Constraints

- Do not authenticate to GCP, run a cloud plan/apply, create cloud resources, or make live-cloud claims during repository development or credential-free CI.
- The future one-time `bootstrap` uses a human's Application Default Credentials to create the state backend, GitHub OIDC/WIF provider, and exactly one `assessment-deployer` service account. After that, GitHub contains non-secret identifiers only—never a service-account key, kubeconfig, Terraform state, plan file, or secret value.
- Terraform owns cloud resources in `infra/bootstrap`, `infra/foundation`, and `infra/platform`; Kustomize owns Kubernetes resources under `k8s/`. Do not introduce a Kubernetes Terraform provider, application source code, Python runtime, pip, pytest, `pyproject.toml`, requirements/lock files, or custom helper framework.
- Both assessed applications use `replicas: 3` and HPA `minReplicas: 3` in every regional production overlay. Grafana is a recoverable supporting workload and is not an assessed application replica set.
- `validate.yml` runs only for pull requests and pushes to `main`, with `permissions: contents: read`. It has no OIDC, secrets, environment, `gcloud`, `bq`, Terraform plan/apply, or cluster access.
- `deploy.yml` and `teardown.yml` are `workflow_dispatch` only, reject non-`main` refs, and use the same `${{ vars.GCP_DEPLOYER_SERVICE_ACCOUNT }}` through short-lived OIDC credentials. Deployment is never automatic.
- Protected GitHub environments, required reviewers, CODEOWNERS, and `main` branch protection are recommended production hardening. Document them precisely, but do not require a bespoke setup script or claim they already exist. Destructive teardown confirmation remains mandatory.
- Teardown requires the exact project ID and literal confirmation `DESTROY <project-id>`, deletes workload/MCI resources before platform and foundation, and must not target bootstrap state, the WIF provider, or the deployer identity.
- Pin application images by digest and external Actions by full commit SHA. Use fixed versions of standard validation tools. Do not add custom repository-contract tests, plan fingerprints, evidence parsers, fake-cloud command harnesses, or parser/test frameworks; the one small Bash manifest renderer is deployment functionality, not a validation framework.
- Terraform plans, generated kubeconfigs, tokens, passwords, Secret Manager values, and sensitive output must not enter Git, logs, job summaries, or uploaded artifacts.
- Documentation must distinguish account-free validation from `deployment-evidence-pending`. No endpoint, screenshot, failover, HPA, BigQuery, Grafana, IAM, or teardown result is live evidence until an authorized run records it.

---

## File Structure

```text
.
├── .github/
│   ├── workflows/{validate,deploy,teardown}.yml
│   └── dependabot.yml
├── Makefile
├── scripts/
│   ├── install-tools.sh
│   ├── render-manifests.sh
│   ├── bootstrap.sh
│   ├── configure-github-variables.sh
│   ├── deploy.sh
│   ├── verify.sh
│   └── teardown.sh
├── infra/{bootstrap,foundation,platform}/
│   ├── *.tf
│   └── *.tftest.hcl
├── k8s/
│   ├── access/
│   ├── base/
│   ├── multicluster/
│   └── overlays/{us-central1,us-east1,config-us-central1}/
├── observability/bigquery/queries/*.sql
├── tools/{versions.env,checksums.sha256,images.env}
├── docs/
│   ├── requirements/{assessment-source.md,traceability.md}
│   ├── architecture/{overview.md,delivery-and-identity.md,traffic-and-observability.md}
│   ├── adr/{0001-autopilot.md,0002-mci-mcs-and-gateway-migration.md,0003-single-oidc-identity.md,0004-public-images-and-secrets.md}
│   ├── setup/{prerequisites.md,bootstrap.md,github.md,deployment.md,dns-tls.md,teardown.md}
│   ├── operations/{verification.md,rollback.md,scaling-and-failover.md,troubleshooting.md}
│   ├── security/{iam-and-secrets.md,supply-chain.md,limitations.md}
│   ├── observability/{grafana.md,bigquery.md}
│   ├── evidence/{checklist.md,status.md,live-evidence-template.md}
│   ├── cost.md
│   ├── references.md
│   └── interview-guide.md
└── README.md
```

Infrastructure and manifests are supplied by the platform implementation plan. This delivery plan adds the lifecycle, standard validation, workflow, and documentation surface; it may add ordinary Terraform `*.tftest.hcl` files beside a root when that root needs a native configuration assertion.

### Task 1: Add the small Bash/Make toolchain and standard validation

**Files:**
- Create: `.editorconfig`, `.gitignore`, `Makefile`, `scripts/install-tools.sh`, `tools/{versions.env,checksums.sha256}`

**Interfaces:**
- Produces Make targets `tools`, `tool-versions`, `fmt`, `validate-terraform`, `validate-kubernetes`, `validate-shell`, `validate-workflows`, `validate-security`, `validate-grafana`, `validate`, `validate-images`, and the guarded human-only `bootstrap` target.
- `make validate` is the credential-free developer/CI contract. It does not call `gcloud`, `bq`, Terraform plan/apply, or an external cloud API.

- [ ] **Step 1: Install only fixed standard CLI tools**

Implement `scripts/install-tools.sh` with `set -euo pipefail`. `tools/versions.env` pins Terraform 1.15.9, kubectl 1.35.8, TFLint 0.64.0, Trivy 0.72.0, Kustomize 5.8.1, Kubeconform 0.7.0, yq 4.53.2, jq 1.8.2, ShellCheck 0.11.0, actionlint 1.7.12, and crane 0.21.7. Install those releases into ignored `.tools/bin`. Verify downloaded archives against the simple committed `tools/checksums.sha256` inventory where the publisher supplies checksums, print each version, and fail for a missing binary or unsupported platform. This is a small shell installer, not a custom validation framework; add no language runtime, package manager, or installer library.

- [ ] **Step 2: Add direct Make targets**

Use simple recipes and explicit Terraform-root loops. This is the validation contract:

```make
SHELL := /usr/bin/env bash
PATH := $(CURDIR)/.tools/bin:$(PATH)

.PHONY: tools tool-versions bootstrap fmt validate-terraform validate-kubernetes validate-shell validate-workflows validate-grafana validate-security validate-images validate

tools:

	./scripts/install-tools.sh

tool-versions:

	@for tool in terraform kubectl tflint trivy kustomize kubeconform yq jq shellcheck actionlint crane; do \
	  command -v $$tool >/dev/null; \
	  $$tool version 2>/dev/null || $$tool --version; \
	done

bootstrap:

	./scripts/bootstrap.sh --project-id "$(PROJECT_ID)" --state-bucket "$(STATE_BUCKET)" \
	  --github-repository "$(GITHUB_REPOSITORY)" --github-owner-id "$(GITHUB_OWNER_ID)" \
	  --github-repository-id "$(GITHUB_REPOSITORY_ID)"

fmt:

	terraform fmt -check -recursive infra

validate-terraform:

	@for root in infra/bootstrap infra/foundation infra/platform; do \
	  terraform -chdir=$$root init -backend=false; \
	  terraform -chdir=$$root validate; \
	  terraform -chdir=$$root test; \
	done
	@for root in infra/bootstrap infra/foundation infra/platform; do \
	  tflint --chdir=$$root --init; \
	  tflint --chdir=$$root; \
	done

validate-kubernetes:

	@for overlay in k8s/access/us-central1 k8s/access/us-east1 k8s/access/config-us-central1 k8s/overlays/us-central1 k8s/overlays/us-east1 k8s/overlays/config-us-central1/http k8s/overlays/config-us-central1/tls k8s/overlays/config-us-central1/https; do \
	  kustomize build $$overlay | kubeconform -strict -summary -ignore-missing-schemas; \
	done
	@find .github k8s -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | \
	  xargs -0 -n1 yq eval '.' >/dev/null
	@for overlay in k8s/overlays/us-central1 k8s/overlays/us-east1; do \
	  kustomize build $$overlay | yq eval-all -e '[select(.kind == "Deployment" and (.metadata.name == "app-a" or .metadata.name == "app-b")) | .spec.replicas] | length == 2 and all(.[]; . == 3)' -; \
	  kustomize build $$overlay | yq eval-all -e '[select(.kind == "HorizontalPodAutoscaler" and (.metadata.name == "app-a" or .metadata.name == "app-b")) | .spec.minReplicas] | length == 2 and all(.[]; . == 3)' -; \
	  kustomize build $$overlay | yq eval-all -e '[select(.kind == "PodDisruptionBudget" and (.metadata.name == "app-a" or .metadata.name == "app-b")) | .spec.minAvailable] | length == 2 and all(.[]; . == 2)' -; \
	done

validate-shell:

	bash -n scripts/*.sh
	shellcheck scripts/*.sh

validate-workflows:

	actionlint .github/workflows/*.yml
	yq -e '.permissions.contents == "read" and (.permissions | length == 1)' .github/workflows/validate.yml >/dev/null
	yq -e '(.on | has("workflow_dispatch")) and (.on | length == 1)' .github/workflows/deploy.yml >/dev/null
	yq -e '(.on | has("workflow_dispatch")) and (.on | length == 1)' .github/workflows/teardown.yml >/dev/null

validate-grafana:

	@find k8s/base/grafana/files/dashboards -type f -name '*.json' -print0 | \
	  xargs -0 -n1 jq empty
	@test "$$(find k8s/base/grafana/files/dashboards -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')" = 3
	@jq -e '([.panels[] | select(.type != "row")] | length) == 4' k8s/base/grafana/files/dashboards/assessment-overview.json

validate-security:

	trivy config --exit-code 1 --severity HIGH,CRITICAL infra
	trivy config --exit-code 1 --severity HIGH,CRITICAL k8s

validate-images:

	@set -a; . ./tools/images.env; set +a; \
	for image in "$$APP_A_IMAGE" "$$APP_B_IMAGE" "$$GRAFANA_IMAGE"; do \
	  printf '%s' "$$image" | grep -Eq '^docker\.io/.+@sha256:[0-9a-f]{64}$$'; \
	  crane digest "$$image" >/dev/null; \
	  trivy image --ignore-unfixed --exit-code 1 --severity HIGH,CRITICAL "$$image"; \
	done

validate: fmt validate-terraform validate-kubernetes validate-shell validate-workflows validate-grafana validate-security
```

`kubeconform -ignore-missing-schemas` permits GKE-specific MCI/MCS resources when published schemas are unavailable while still strictly checking recognized Kubernetes resources. Do not add a broad custom test to replace that tool behavior.

- [ ] **Step 3: Verify and commit the shared harness**

Run:

```bash
make tools
make tool-versions
bash -n scripts/install-tools.sh
shellcheck scripts/install-tools.sh
git add .editorconfig .gitignore Makefile scripts/install-tools.sh tools/versions.env tools/checksums.sha256
git commit -m "build: add reproducible shell toolchain"
```

Expected: every pinned compiled CLI reports the intended version and the installer passes static shell checks. Do not run `make validate` until the infrastructure, workload, workflow, and dashboard inputs exist.

### Task 2: Add safe future bootstrap, deployment, verification, and teardown scripts

**Files:**
- Create: `scripts/{render-manifests,bootstrap,configure-github-variables,deploy,verify,teardown}.sh`
- Modify: `Makefile`

**Interfaces:**
- `bootstrap.sh --project-id ID --state-bucket BUCKET --github-repository OWNER/REPO --github-owner-id ID --github-repository-id ID` is the one-time human-credential operation.
- `configure-github-variables.sh --repository OWNER/REPO --outputs FILE` configures non-secret repository variables only.
- `render-manifests.sh`, `deploy.sh foundation|platform|workloads`, `verify.sh smoke`, `verify.sh hpa`, `verify.sh failover`, and `teardown.sh --project-id ID --confirmation "DESTROY ID"` are future manual-workflow/operator entry points.
- Human bootstrap requires Google Cloud CLI 582.0.0. Authenticated GitHub jobs install that same version plus `gke-gcloud-auth-plugin` and `bq` through the pinned Google setup action; these cloud CLIs are intentionally outside the credential-free `.tools` installer.

- [ ] **Step 1: Implement one-time bootstrap**

`bootstrap.sh` rejects `GITHUB_ACTIONS=true`, requires `gcloud auth application-default print-access-token` to succeed without displaying its token, and requires a typed project-ID confirmation before `terraform apply` in `infra/bootstrap`. It creates the versioned GCS state backend, repository-scoped GitHub OIDC/WIF provider, and single `assessment-deployer` identity defined by Terraform. Write only non-secret Terraform outputs to a mode-0600 ignored generated file, then call `configure-github-variables.sh` when `gh auth status` is available.

Do not create a service-account key. Do not copy credentials, state, Terraform plans, or secrets into GitHub. The future human command is:

```bash
make bootstrap PROJECT_ID=example-project STATE_BUCKET=example-project-tfstate \
  GITHUB_REPOSITORY=OWNER/REPO GITHUB_OWNER_ID=123 GITHUB_REPOSITORY_ID=456
```

- [ ] **Step 2: Configure non-secret repository variables and recommend governance**

Populate only:

```text
GCP_PROJECT_ID
GCP_PROJECT_NUMBER
GCP_WIF_PROVIDER
GCP_DEPLOYER_SERVICE_ACCOUNT
TF_STATE_BUCKET
GCP_REGION_PRIMARY
GCP_REGION_SECONDARY
GCP_ENABLE_HTTPS
GCP_MANAGE_DNS
GCP_CREATE_DNS_ZONE
GCP_DNS_NAME
GCP_DNS_ZONE_NAME
GCP_DNS_ZONE_DNS_NAME
```

Set the HTTPS/DNS booleans to `false` and DNS strings to empty for the immediately deployable HTTP baseline; no source edit is required. Print a manual `gh variable set` fallback when GitHub CLI access is unavailable. Do not create environments, reviewers, branch rules, or secrets in this script; documentation recommends protected `production`/`teardown` environments, reviewers, prevent-self-review, CODEOWNERS, and `main` protection as production hardening.

- [ ] **Step 3: Implement guarded Terraform and workload deployment**

`deploy.sh foundation` and `deploy.sh platform` run `terraform init`, create a mode-0600 temporary plan with `terraform plan -out`, print only resource addresses and action types from `terraform show -json | jq`, immediately apply that same job-local plan, and remove it through a trap. Saved plans are never uploaded or transferred between jobs.

`render-manifests.sh` copies renders into ignored `.generated/`, validates every substitution value against its expected identifier/IP/email form, replaces only the approved Terraform output tokens with ordinary `sed`, and fails if any `${...}` token remains. It does not depend on `envsubst` or a language runtime. `deploy.sh workloads` first creates a mode-0600 ephemeral kubeconfig for each exact cluster through its IAM-aware DNS endpoint and applies only the namespace and `k8s/access/*` overlays. It then creates fresh Connect Gateway kubeconfigs and applies the rendered regional workload and MCI/MCS overlays through the configured Fleet memberships. Create initial App A/Grafana Secret Manager versions at deployment time by piping `openssl rand` to `gcloud secrets versions add --data-file=-`; never place values in Terraform, GitHub variables, argv, output, or artifacts. Use bounded rollout/reconciliation waits and fail on timeout.

- [ ] **Step 4: Implement normal smoke verification and optional controlled drills**

`verify.sh smoke` checks Fleet/cluster readiness, three Ready replicas for each assessed application in each cluster, rollout success, MCI/MCS/backend health, HTTP `/app-a` and `/app-b`, optional HTTPS after certificate activation, BigQuery log availability, and Grafana health/dashboard provisioning. It renders only the project/dataset tokens and validates each committed BigQuery SQL file after deployment; data queries receive bounded time parameters while the metadata query does not:

```bash
for query_file in observability/bigquery/queries/*.sql; do
  query_text="$(sed -e "s|\${GCP_PROJECT_ID}|${GCP_PROJECT_ID}|g" -e "s|\${BIGQUERY_DATASET}|${BIGQUERY_DATASET}|g" "${query_file}")"
  query_parameters=()
  if [[ "${query_file}" != */schema-discovery.sql ]]; then
    query_parameters+=(--parameter=start_time:TIMESTAMP:"${VERIFY_START_TIME}")
    query_parameters+=(--parameter=end_time:TIMESTAMP:"${VERIFY_END_TIME}")
  fi
  bq query --project_id="${GCP_PROJECT_ID}" --dry_run --use_legacy_sql=false "${query_parameters[@]}" "${query_text}"
done
```

Store only redacted timestamps, resource names, status classes, and command output in `artifacts/live/`; do not capture response bodies, tokens, secret values, kubeconfig, state, or plans.

Keep HPA and regional-failover exercises out of normal deployment. `verify.sh hpa --region us-central1 --confirm "HPA us-central1"` and `verify.sh failover --region us-east1 --confirm "FAILOVER us-east1"` require exact confirmation, use bounded timeouts, and restore committed workloads with a `trap` even after interruption. Label both as controlled application exercises, not cluster-outage claims.

- [ ] **Step 5: Implement destructive teardown**

Before mutation, `teardown.sh` checks it is running from `main`, requires the dispatched project ID to equal `GCP_PROJECT_ID`, and requires `--confirmation "DESTROY <project-id>"`. It deletes Kubernetes MCI/MCS/workloads first, waits for managed load-balancer cleanup, then destroys platform and foundation in that order. It refuses bootstrap directories/state targets and reports retained bootstrap state, WIF, deployer identity, and state bucket separately from deleted assessment resources.

- [ ] **Step 6: Run only static script checks**

Run:

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
make validate-shell
```

Expected: scripts pass static checks. Do not execute bootstrap, deployment, verification, drills, teardown, `gcloud`, or `bq` while implementing this plan.

- [ ] **Step 7: Commit lifecycle scripts**

```bash
git add Makefile scripts/render-manifests.sh scripts/bootstrap.sh scripts/configure-github-variables.sh scripts/deploy.sh scripts/verify.sh scripts/teardown.sh
git commit -m "feat: add guarded deployment lifecycle scripts"
```

### Task 3: Add credential-free CI and manual lifecycle workflows

**Files:**
- Create: `.github/workflows/{validate,deploy,teardown}.yml`, `.github/dependabot.yml`
- Modify: `Makefile`, `scripts/{deploy,verify,teardown}.sh`

**Interfaces:**
- `validate.yml` invokes `make tools` and `make validate` without Google authentication.
- `deploy.yml` offers boolean `run_hpa_drill` and `run_failover_drill` inputs, both defaulting to `false`; it calls the deployment script and then `verify.sh smoke`.
- `teardown.yml` requires `project_id` and `confirmation` dispatch inputs before it calls the teardown script.

- [ ] **Step 1: Implement `validate.yml`**

Trigger only on `pull_request` and `push` to `main`, and set:

```yaml
permissions:
  contents: read
```

Use full-SHA-pinned `actions/checkout`, run `make tools`, `make validate`, and `make validate-images`. This workflow has no `id-token: write`, `gcloud`, `bq`, credential, environment, Terraform plan/apply, or deployment command. If retaining reports, upload only rendered manifests and non-sensitive lint/scan results; never upload plans, state, generated kubeconfig, or live evidence.

- [ ] **Step 2: Implement `deploy.yml`**

Use `workflow_dispatch` only, guard `github.ref == 'refs/heads/main'`, and use a non-cancelling production concurrency group. Each privileged job authenticates using a full-SHA-pinned Google auth Action with `${{ vars.GCP_WIF_PROVIDER }}`, the same `${{ vars.GCP_DEPLOYER_SERVICE_ACCOUNT }}`, and audience `https://iam.googleapis.com/${{ vars.GCP_WIF_PROVIDER }}`. Immediately afterward, a full-SHA-pinned `google-github-actions/setup-gcloud` step installs version `582.0.0` with components `gke-gcloud-auth-plugin,bq`. Set `CLOUDSDK_CORE_PROJECT=${{ vars.GCP_PROJECT_ID }}` and `USE_GKE_GCLOUD_AUTH_PLUGIN=True` before any `gcloud`, `bq`, or Kubernetes command. The ordered workflow is:

```text
credential-free validation
  -> deploy foundation
  -> deploy platform and workloads
  -> smoke verification, including BigQuery SQL dry runs
  -> optional HPA drill
  -> optional regional-failover drill
```

Each drill runs only when its boolean dispatch input is true and passes the exact script confirmation. Upload only redacted results. Baseline jobs do not reference a GitHub Environment because that would change the OIDC subject. The hardening guide explains that adopting protected Environments requires adding their exact subjects to the WIF condition before changing the workflows.

- [ ] **Step 3: Implement `teardown.yml`**

Use `workflow_dispatch` only, require `project_id` and `confirmation`, guard `main` before authentication, use the deploy concurrency group and the same OIDC identity/audience, install Google Cloud CLI 582.0.0 and `gke-gcloud-auth-plugin` through the same pinned setup action, then invoke `scripts/teardown.sh`. A separate protected `teardown` environment and approval are recommended production hardening; adopting it also requires adding its exact subject to the WIF condition. Upload only the redacted cleanup report.

- [ ] **Step 4: Pin dependencies and lint workflows**

Pin every third-party `uses:` value to a 40-character commit SHA. Add Dependabot only for GitHub Actions updates; it opens reviewable pull requests and does not auto-merge. Do not add a Python setup action, pip dependencies, custom workflow parser, or workflow-text contract test.

Run:

```bash
actionlint .github/workflows/*.yml
yq eval '.' .github/workflows/validate.yml >/dev/null
yq eval '.' .github/workflows/deploy.yml >/dev/null
yq eval '.' .github/workflows/teardown.yml >/dev/null
make validate
```

Expected: standard credential-free checks pass. Manually inspect the workflow files for dispatch-only deployment/teardown, one federated identity, no static cloud credential, and default-disabled drills.

- [ ] **Step 5: Commit workflow automation**

```bash
git add .github/workflows/validate.yml .github/workflows/deploy.yml .github/workflows/teardown.yml .github/dependabot.yml
git commit -m "ci: add OIDC deployment lifecycle workflows"
```

### Task 4: Write deploy-ready documentation, traceability, and honest evidence status

**Files:**
- Move unchanged: `docs/requirments.md` to `docs/requirements/assessment-source.md`
- Create: all documentation files listed in File Structure
- Modify: `README.md`

**Interfaces:**
- `docs/requirements/traceability.md` maps each assessment requirement to implementation path, account-free validation command, future live verification, evidence destination, and current status.
- `docs/evidence/status.md` uses `verified-account-free`, `deployment-evidence-pending`, and `not-applicable` until a real authorized run completes a row from `live-evidence-template.md`.
- `README.md` provides the shortest safe operator path and links to detailed guides.

- [ ] **Step 1: Preserve requirements and create traceability**

Copy the supplied source byte-for-byte, verify it, then remove the misspelled source path:

```bash
cmp docs/requirments.md docs/requirements/assessment-source.md
```

Create a traceability table covering both GKE regions, both applications and the three-replica/HPA baseline, MCI/MCS/global routing/failover, Cloud Armor, Workload Identity/Secret Manager, BigQuery logging, Grafana and four overview panels, Terraform, OIDC workflows, troubleshooting, cost, deployment, and teardown. Each row distinguishes a static command from a live-only command and begins in an honest status.

- [ ] **Step 2: Document architecture and decisions**

Write topology, traffic, observability, Terraform-state-boundary, and delivery/identity diagrams. Record ADRs for Autopilot, rubric-first MCI/MCS plus future multi-cluster Gateway API migration, one `assessment-deployer` OIDC identity, and digest-pinned public images/Secret Manager. Explain the single-identity blast-radius trade-off and recommend production role separation without claiming it exists.

Document the HTTP-first verification path, optional owned-domain DNS/TLS path, Cloud Armor, private GKE/Fleet access, Grafana's recoverable primary-cluster role, partition-bounded BigQuery queries, and the third-party-image limits for Trace, Profiler, and Error Reporting. Include cost controls and billable components without presenting the architecture as free tier.

- [ ] **Step 3: Document setup, hardening, and operation**

Provide exact future commands for account-free validation, installing Google Cloud CLI 582.0.0 with `gke-gcloud-auth-plugin` and `bq`, human bootstrap, variable configuration, manual deployment, smoke verification, optional drills, rollback, and teardown. Mark every cloud-mutating command and describe cost impact. Explain that DNS is optional for HTTP verification but required for a managed-certificate/HTTPS path.

In `docs/setup/github.md`, recommend protecting `main`, requiring the `validate` check, CODEOWNERS, protected `production`/`teardown` environments, reviewers, prevent-self-review, and deployment-branch restrictions. Explain that changing jobs from the baseline branch subject to Environment subjects requires updating the Terraform WIF allowlist first. These are a production governance checklist, not bespoke prerequisite automation.

Cover OIDC/WIF bootstrap, no-key policy, state handling, image/digest scanning, Secret Manager runtime mounting, Grafana access, rollout/rollback, controlled scaling/failover, DNS/TLS troubleshooting, and reverse-order teardown. Include the planned controlled readiness-probe exercise—symptom, diagnosis, correction, expected recovery, prevention—and label it accurately until executed.

- [ ] **Step 4: Complete the evidence model without fabricating claims**

`docs/evidence/checklist.md` lists post-deployment collection: cluster/Fleet readiness, six ready replicas per application across both regions, MCI backend health, HTTP/optional HTTPS, HPA/failover drill output only when deliberately run, BigQuery dry-run/query output, Grafana export or screenshot, and teardown/residual report. `live-evidence-template.md` requires UTC time, commit SHA, workflow URL, actor/reviewer, redaction note, command, result, and artifact location before a record may become `verified-live`.

Initialize `status.md` only with account-free results actually run; all cloud-dependent rows are `deployment-evidence-pending`. Committed Grafana dashboard JSON satisfies the assessment's export alternative without inventing a live screenshot.

- [ ] **Step 5: Review documentation and clean repository state**

Run:

```bash
make validate
git diff --check
find . -type f \( -name '*.tfplan' -o -name '*.tfstate' -o -name '*.pem' -o -name '*service-account*.json' -o -name 'kubeconfig*' \) -not -path './.git/*' -print
```

Expected: validation and whitespace checks pass; the final command prints no generated plan, state, key, service-account credential, or kubeconfig.

- [ ] **Step 6: Commit documentation and the requirements move**

```bash
git add README.md docs
git add -u docs/requirments.md
git commit -m "docs: add assessment operations and decision record"
```

## Cross-Plan Interface Changes

- The infrastructure plan must expose non-secret bootstrap outputs for `GCP_PROJECT_ID`, `GCP_PROJECT_NUMBER`, `GCP_WIF_PROVIDER`, `GCP_DEPLOYER_SERVICE_ACCOUNT`, and `TF_STATE_BUCKET`; this plan writes and consumes them as GitHub repository variables.
- Terraform roots remain the only cloud-resource source and use only native `*.tftest.hcl` tests. This plan removes Python, pip/pytest, plan-fingerprint summaries, evidence parsers, fake-cloud helpers, and broad repository-contract test suites from the delivery interface; one small Bash manifest renderer remains a deployment function.
- The Kubernetes plan provides `k8s/access/*`, `k8s/overlays/us-central1`, `k8s/overlays/us-east1`, and `k8s/overlays/config-us-central1/*`, including narrow pipeline RBAC, MCI/MCS, and digest-pinned application images. This plan builds and schema-validates those overlays, applying them only in a future manual workflow.
- The observability plan provides Grafana dashboard JSON under `k8s/base/grafana/files/dashboards/` and BigQuery SQL under `observability/bigquery/queries/`. Pre-deploy checks validate dashboard JSON only; `bq query --dry_run --use_legacy_sql=false` runs only after OIDC in post-deploy smoke verification.
- Operations use small Bash entry points and Make, not a custom framework. Deployment/teardown remain manually dispatched with one OIDC-federated identity. Protected environments and branch protection are documented recommendations; destructive teardown confirmation is still enforced.

## Live-Only Boundary

Until an authorized manual deployment is recorded, the repository may claim only completed account-free checks. It must not claim a cloud Terraform plan/apply, state lock, cluster/Fleet readiness, Fleet access, MCI backend health, public endpoint, certificate, HPA response, failover, BigQuery result, Grafana health, Secret Manager mount, IAM behavior, screenshot, teardown, or residual-resource result. Record each only through the live-evidence template after redaction.
