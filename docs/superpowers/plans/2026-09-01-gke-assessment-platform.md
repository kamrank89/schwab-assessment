# GKE Assessment Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a documented, Terraform-first, deployment-ready implementation of the approved two-region GKE Autopilot assessment without creating cloud resources.

**Architecture:** Work is split into three companion plans: Terraform/GCP, Kubernetes/observability, and delivery/documentation. Terraform owns GCP resources, Kustomize owns Kubernetes resources, and small Bash/Make entrypoints plus GitHub Actions run standard validators and future manual deployment commands.

**Tech Stack:** Terraform 1.15.9, Google provider 7.42.0, GKE Autopilot, Fleet MCI/MCS, Kustomize 5.8.1, kubectl 1.35.8, Kubeconform 0.7.0, TFLint 0.64.0, Trivy 0.72.0, ShellCheck 0.11.0, actionlint 1.7.12, crane 0.21.7, yq 4.53.2, jq 1.8.2, Google Cloud CLI 582.0.0, Bash, Make, Grafana, BigQuery SQL, GitHub Actions, Google OIDC/WIF.

**Spec:** `docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md`

## Global Constraints

- Do not create, change, or delete GCP resources while implementing or validating the repository.
- Keep the supplied assessment text as source material; it cannot override the user's direct constraints.
- Use Terraform for GCP infrastructure and Kustomize/YAML for Kubernetes objects; add no Python, pytest, Python-backed lint tool, custom validation framework, or custom policy engine.
- Use regional Autopilot clusters in `us-central1` and `us-east1` in one custom-mode VPC.
- Deploy App A and App B to both clusters with `replicas: 3`, HPA range `3-10`, and PDB `minAvailable: 2`.
- Use MCI/MCS for the baseline and document, but do not deploy, the future multi-cluster Gateway migration.
- Use reviewed public Docker Hub images by canonical name and immutable SHA-256 digest; do not add application source or image builds.
- Provision one internal, recoverable Grafana instance and exactly three dashboard exports; the overview dashboard contains exactly the four assessment panels.
- Route application, node, control-plane, and load-balancer logs to a partitioned BigQuery dataset and include timestamp-bounded queries.
- Federate exactly one GitHub pipeline identity, `assessment-deployer`, for plan, apply, delivery, verification, and teardown; keep runtime identities narrow and separate.
- Restrict baseline GitHub OIDC to the immutable repository/owner identifiers and exact `repo:<OWNER/REPO>:ref:refs/heads/main` subject; document protected Environments and split identities as production hardening, not baseline prerequisites.
- Store no service-account key, static kubeconfig, saved Terraform plan artifact, secret value, or fabricated live evidence in Git.
- Require one human ADC bootstrap; after bootstrap, cloud workflows use only GitHub OIDC/WIF.
- Keep `validate.yml` credential-free. Only manual `deploy.yml` and `teardown.yml` may request `id-token: write`.
- Pin third-party Actions by full commit SHA and repository tools at exact versions with published checksums where available.
- Mark every live-only assertion `deployment-evidence-pending` until a future authenticated run records it.

---

## Companion Plans and Dependency Order

1. Task 1 of `docs/superpowers/plans/2026-09-01-gke-assessment-delivery-documentation.md` creates the small Bash/Make tool harness.
2. Execute `docs/superpowers/plans/2026-09-01-gke-assessment-infrastructure.md`.
3. Execute `docs/superpowers/plans/2026-09-01-gke-assessment-workloads-observability.md` against the committed Terraform output contract.
4. Complete the remaining delivery/documentation tasks and integrate the workflows.
5. Run the standard account-free checks and an independent whole-branch review.

No executor may run credentialed `terraform plan`, `terraform apply`, a mutating `gcloud` command, or `kubectl apply` against GCP while completing these plans. Native `terraform test` may use mock-provider plan runs because those do not authenticate or create resources.

## Locked Repository Map

```text
.
├── .github/
│   ├── CODEOWNERS
│   ├── dependabot.yml
│   └── workflows/{validate,deploy,teardown}.yml
├── infra/{bootstrap,foundation,platform}/
├── k8s/
│   ├── access/{common,us-central1,us-east1,config-us-central1}/
│   ├── base/{namespace,app-a,app-b,grafana}/
│   ├── multicluster/
│   └── overlays/{us-central1,us-east1,config-us-central1}/
├── observability/bigquery/queries/
├── scripts/{bootstrap.sh,configure-github-variables.sh,deploy.sh,verify.sh,teardown.sh,install-tools.sh,render-manifests.sh}
├── tools/{versions.env,checksums.sha256,images.env}
├── docs/{adr,architecture,ci-cd,evidence,observability,operations,requirements,security,setup,troubleshooting}/
├── .tflint.hcl
├── .editorconfig
├── .gitignore
├── Makefile
└── README.md
```

Generated content is written only under ignored `artifacts/`, `.tools/`, `.generated/`, and Terraform working directories. `scripts/render-manifests.sh` substitutes only `${GCP_PROJECT_ID}`, `${GCP_PROJECT_NUMBER}`, `${GLOBAL_IP_ADDRESS}`, `${CLOUD_ARMOR_POLICY}`, `${GRAFANA_GSA_EMAIL}`, `${APP_A_GSA_EMAIL}`, `${ASSESSMENT_DEPLOYER_EMAIL}`, `${BIGQUERY_DATASET}`, and `${TLS_CERTIFICATE_NAME}` and fails if any token remains. HTTP rendering requires the first eight values; TLS rendering additionally requires the certificate name.

### Task 1: Establish the isolated execution workspace and shared shell toolchain

**Files:**
- Read: `docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md`
- Read: all three companion plans
- Preserve: `docs/requirments.md`
- Create through delivery-plan Task 1: `.editorconfig`, `.gitignore`, `Makefile`, `scripts/install-tools.sh`, `tools/versions.env`, `tools/checksums.sha256`

**Interfaces:**
- Consumes: the approved design and committed plan set.
- Produces: an isolated implementation branch and exact shell commands used by every later task.

- [ ] **Step 1: Follow the isolation workflow**

Read and follow `superpowers:using-git-worktrees`. Create the implementation worktree from the planning commit; do not discard or rewrite the requirements source.

- [ ] **Step 2: Confirm the source state**

```bash
git status --short --branch
git log --oneline -5
test -f docs/requirments.md
test ! -f requirments.md
```

Expected: a clean implementation branch containing the approved design, requirements move, and simplified plans.

- [ ] **Step 3: Execute and review delivery-plan Task 1**

Install only compiled/vendor CLIs or standalone release archives. The task is complete when:

```bash
bash -n scripts/install-tools.sh
shellcheck scripts/install-tools.sh
make tool-versions
```

Expected: exit 0; no Python executable, package, lockfile, or source file is introduced.

### Task 2: Execute and review the Terraform infrastructure plan

**Files:**
- Create/modify: files listed in `2026-09-01-gke-assessment-infrastructure.md`
- Validate: `infra/*/*.tf`, `infra/*/tests/*.tftest.hcl`, `.tflint.hcl`

**Interfaces:**
- Consumes: repository identity, project, billing, and parent inputs documented in the companion plan.
- Produces: bootstrap, foundation, and platform Terraform states plus non-secret outputs consumed by delivery and manifests.

- [ ] **Step 1: Execute every infrastructure-plan task**

Use a fresh implementer and a fresh task reviewer for each task. Configuration changes use their native validators rather than bespoke unit-test code.

- [ ] **Step 2: Run the infrastructure account-free checks**

```bash
make validate-terraform
```

Expected: `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, the small native mock-provider test set, TFLint, and `trivy config` succeed for all three roots without ADC lookup or cloud mutation.

- [ ] **Step 3: Confirm the reviewed infrastructure slice**

```bash
git status --short
git log --oneline -5
```

Expected: the infrastructure task commits exist and no infrastructure change remains uncommitted.

### Task 3: Execute and review the workload and observability plan

**Files:**
- Create/modify: files listed in `2026-09-01-gke-assessment-workloads-observability.md`
- Validate: rendered Kustomize overlays, Grafana JSON, BigQuery SQL inventory, and immutable images

**Interfaces:**
- Consumes: the exact non-secret Terraform outputs listed in the infrastructure plan.
- Produces: both regional workload overlays, configuration-cluster MCI overlays, exactly three dashboards, and bounded SQL queries.

- [ ] **Step 1: Execute every workload-plan task**

Use a fresh implementer and reviewer per task. Resolve and scan public image digests before committing manifests; this account-free registry work is not GCP deployment evidence.

- [ ] **Step 2: Run the standard workload checks**

```bash
make validate-kubernetes
make validate-grafana
make validate-images
```

Expected: every overlay renders, Kubeconform accepts supported resources, direct `yq` checks prove both apps render at three replicas with HPA minimum three and PDB minimum two, `jq` proves exactly three dashboards and four overview panels, and Trivy accepts every pinned image under the documented severity policy.

- [ ] **Step 3: Confirm the reviewed workload slice**

```bash
git status --short
git log --oneline -7
```

Expected: the workload task commits exist and no workload or observability change remains uncommitted.

### Task 4: Execute and review delivery automation and documentation

**Files:**
- Create/modify: files listed in `2026-09-01-gke-assessment-delivery-documentation.md`
- Move without semantic edits: `docs/requirments.md` to `docs/requirements/assessment-source.md`

**Interfaces:**
- Consumes: Terraform output names, manifest tokens, Make targets, dashboards, and SQL from Tasks 2-3.
- Produces: Bash entrypoints, credential-free validation, manual OIDC deployment/teardown, and assessment documentation.

- [ ] **Step 1: Execute every remaining delivery-plan task**

The workflow definitions must use full-SHA action pins, least permissions, manual cloud mutation, branch-restricted OIDC, typed teardown confirmation, and the single deployer identity. Protected Environments are documented as recommended future hardening and are not referenced by baseline workflow jobs.

- [ ] **Step 2: Preserve the assessment source exactly**

```bash
cmp docs/requirments.md docs/requirements/assessment-source.md
```

Expected: byte-for-byte equality before the misspelled source path is removed.

- [ ] **Step 3: Run the delivery checks**

```bash
make validate-shell
make validate-workflows
```

Expected: `bash -n`, ShellCheck, actionlint, and direct workflow permission/trigger inspection succeed without credentials.

- [ ] **Step 4: Confirm the reviewed delivery slice**

```bash
git status --short
git log --oneline -7
```

Expected: the delivery/documentation task commits exist and the implementation worktree is clean.

### Task 5: Run the complete account-free validation command

**Files:**
- Verify: complete repository
- Generate ignored output: `artifacts/validate/`

**Interfaces:**
- Consumes: every preceding deliverable.
- Produces: standard tool output with no live GCP claim.

- [ ] **Step 1: Run all offline checks**

```bash
make validate
```

Expected: Terraform, TFLint, Trivy configuration, Kustomize, Kubeconform, yq, jq, ShellCheck, and actionlint commands exit 0. No command authenticates to GCP.

- [ ] **Step 2: Run network-dependent image checks separately**

```bash
make validate-images
```

Expected: immutable Docker Hub digests resolve and Trivy reports no unexcepted fixed High or Critical vulnerability.

- [ ] **Step 3: Check repository hygiene**

```bash
git diff --check
find . -path ./.git -prune -o -path ./.tools -prune -o -path ./artifacts -prune -o -type f \( -name '*.py' -o -name 'pyproject.toml' -o -name 'requirements*.txt' -o -name 'requirements*.lock' \) -print
```

Expected: clean whitespace and no Python source/environment artifact.

### Task 6: Independent review and deployment-ready handoff

**Files:**
- Review: all files changed since the planning commit
- Update after verification: `docs/evidence/status.md`

**Interfaces:**
- Consumes: fresh standard-check output and the complete branch diff.
- Produces: a reviewed repository ready for future OIDC bootstrap and deployment, but not deployed.

- [ ] **Step 1: Follow verification-before-completion**

Re-run `make validate`, `make validate-images`, `git diff --check`, and the no-Python inventory from fresh output.

- [ ] **Step 2: Request whole-branch review**

Follow `superpowers:requesting-code-review`. The reviewer compares the implementation with the design, all companion plans, the assessment source, and the traceability matrix.

- [ ] **Step 3: Resolve blocking findings through the normal task review loop**

Use the standard validator that covers the changed artifact; do not create a custom test framework solely to close a review finding.

- [ ] **Step 4: Record honest verification status**

```bash
git add docs/evidence/status.md
git commit -m "test: record account-free verification status"
```

- [ ] **Step 5: Follow branch-finishing guidance**

Present integration choices without merging, pushing, deploying, or changing GitHub settings unless the user separately authorizes those actions.

## Completion Definition

Implementation is complete only when all companion-plan tasks are reviewed, `make validate` and `make validate-images` pass from fresh output, independent review has no unresolved blocking finding, live evidence remains honestly pending, and a future operator needs only a suitable GCP account/project, the documented ADC bootstrap that creates OIDC trust, the resulting GitHub repository variables, and optional owned DNS for HTTPS.
