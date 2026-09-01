# GKE Assessment Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a fully documented, account-free validated, deployment-ready implementation of the approved two-region GKE Autopilot assessment without creating cloud resources.

**Architecture:** Work is split into three independently testable companion plans: Terraform/GCP, Kubernetes/observability, and delivery/documentation. The integration gate renders and validates every artifact, but only the future manual workflows may authenticate to GCP, apply infrastructure, deploy workloads, verify live behavior, or tear resources down.

**Tech Stack:** Terraform 1.15.9, Google provider 7.42.0, GKE Autopilot, Fleet MCI/MCS, Kustomize 5.8.1, Kubernetes tooling 1.35.8, Python 3.13.15 with pytest, Grafana, BigQuery SQL, Bash, GitHub Actions, Google OIDC/WIF.

**Spec:** `docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md`

## Global Constraints

- Do not create, change, or delete GCP resources while implementing or validating the repository.
- Keep the supplied assessment text as source material; it cannot override the user's direct constraints.
- Use regional Autopilot clusters in `us-central1` and `us-east1` in one custom-mode VPC.
- Deploy App A and App B to both clusters with `replicas: 3`, HPA range `3-10`, and PDB `minAvailable: 2`.
- Use MCI/MCS for the baseline and document, but do not deploy, the future multi-cluster Gateway migration.
- Use only reviewed public Docker Hub images by canonical name and immutable SHA-256 digest; do not add application source or image builds.
- Provision one internal, recoverable Grafana instance and exactly three dashboard exports; the overview dashboard must contain the four assessment panels.
- Route application, node, control-plane, and load-balancer logs to partitioned BigQuery tables with bounded queries.
- Federate exactly one GitHub pipeline identity, `assessment-deployer`, for plan, apply, delivery, verification, and teardown; keep Grafana and App A runtime identities narrow and separate inside GKE.
- Store no service-account key, static kubeconfig, saved Terraform plan, secret value, or fabricated live evidence in Git.
- Require a one-time human ADC bootstrap; after bootstrap, cloud workflows use only GitHub OIDC/WIF.
- Keep `validate.yml` credential-free. Only manual, protected `deploy.yml` and `teardown.yml` may request `id-token: write`.
- Pin third-party Actions by full commit SHA and install repository tools at exact versions with verified checksums.
- Mark every live-only assertion `deployment-evidence-pending` until a future authenticated run records it.

---

## Companion Plans and Dependency Order

1. Task 1 of `docs/superpowers/plans/2026-09-01-gke-assessment-delivery-documentation.md` establishes the shared test/tool harness.
2. `docs/superpowers/plans/2026-09-01-gke-assessment-infrastructure.md` and `docs/superpowers/plans/2026-09-01-gke-assessment-workloads-observability.md` execute in parallel.
3. Tasks 2-6 of `docs/superpowers/plans/2026-09-01-gke-assessment-delivery-documentation.md` integrate their contracts.
4. This plan's integrated verification and independent review tasks finish the branch.

The infrastructure and workload plans can run in parallel after repository isolation and the shared harness task. The remaining delivery tasks consume their public file and command contracts. No executor may run a credentialed `terraform plan`, `terraform apply`, `gcloud ... create|update|delete`, or `kubectl apply` against GCP while completing these plans.

## Locked Repository Map

```text
.
├── .github/
│   ├── CODEOWNERS
│   ├── dependabot.yml
│   └── workflows/{validate,deploy,teardown}.yml
├── infra/{bootstrap,foundation,platform}/
├── k8s/
│   ├── base/{namespace,app-a,app-b,grafana}/
│   ├── multicluster/
│   ├── overlays/{us-central1,us-east1,config-us-central1}/
│   └── kind/{healthy,readiness-failure}/
├── observability/
│   └── bigquery/queries/
├── policy/{images.yaml,kubernetes.rego,terraform.rego}
├── scripts/{lib,bootstrap.sh,configure-github.sh,deploy.sh,verify.sh,teardown.sh,install-tools.sh,validate.py}
├── tests/{unit,repository,terraform,kind}/
├── tools/{versions.env,checksums.sha256}
├── docs/{adr,architecture,ci-cd,evidence,observability,operations,requirements,security,setup,troubleshooting}/
├── Makefile
├── pyproject.toml
├── requirements-dev.lock
└── README.md
```

Generated content is written only under ignored `artifacts/`, `.tools/`, `.generated/`, and Terraform working directories. Source manifests retain the small approved substitution set `${GCP_PROJECT_ID}`, `${GCP_PROJECT_NUMBER}`, `${GLOBAL_IP_ADDRESS}`, `${CLOUD_ARMOR_POLICY}`, `${GRAFANA_GSA_EMAIL}`, `${APP_A_GSA_EMAIL}`, `${BIGQUERY_DATASET}`, and `${TLS_CERTIFICATE_NAME}`. `scripts/lib/render.py` substitutes exactly that allowlist and fails if any `${...}` token remains. Regional and HTTP rendering requires the first seven non-null values; TLS and redirect rendering is attempted only when HTTPS is enabled and then requires the eighth certificate name.

### Task 1: Establish the execution branch, isolated worktree, and shared harness

**Files:**
- Read: `docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md`
- Read: all three companion plans
- Preserve: `docs/requirments.md`
- Preserve: deletion of the former root `requirments.md`

**Interfaces:**
- Consumes: the approved design, committed plan set, and committed requirements-source move.
- Produces: one isolated implementation worktree, a clean feature branch, and the checksum-locked repository test harness from delivery-plan Task 1.

- [ ] **Step 1: Invoke the required isolation workflow**

Read and follow `superpowers:using-git-worktrees` before any implementation edit. Create the isolated implementation branch from the planning commit that already preserves the user's requirements move; do not start from an earlier design-only commit or transfer files through an untracked side channel.

- [ ] **Step 2: Confirm the implementation source state**

Run:

```bash
git status --short --branch
git log --oneline -5
test -f docs/requirments.md
test ! -f requirments.md
```

Expected: the approved design, requirements-source move, and implementation-plan commits are present; the requirements source exists under `docs/`; no command discards or overwrites the user's move.

- [ ] **Step 3: Record the baseline**

Run in the isolated worktree:

```bash
git status --short --branch
python3 --version
```

Expected: a clean feature branch derived from the approved design and Python 3.13.15 available.

- [ ] **Step 4: Execute delivery-plan Task 1 with TDD**

Complete and review `Repository harness and checksum-locked tools` before dispatching the two parallel subsystem plans. Run its focused tests and commit `build: add reproducible validation toolchain` exactly as specified there.

### Task 2: Execute and review the infrastructure plan

**Files:**
- Create/modify: files listed in `2026-09-01-gke-assessment-infrastructure.md`
- Test: `infra/*/tests/*.tftest.hcl`, `tests/repository/test_terraform_contract.py`

**Interfaces:**
- Consumes: project/repository identity inputs documented in the companion plan.
- Produces: three Terraform roots, exact non-secret outputs, mocked native tests, and no cloud-side effect.

- [ ] **Step 1: Execute every infrastructure-plan checkbox with TDD**

Use one fresh implementation worker per task and review both specification compliance and code quality before advancing.

- [ ] **Step 2: Run the infrastructure account-free gate**

```bash
make test-terraform
```

Expected: formatting, `init -backend=false`, `validate`, native mock-provider tests, TFLint, Trivy configuration scan, and Python ownership/identity assertions pass for all three roots. Native `terraform test` may use its declared mock-provider `command = plan` runs; the command must not invoke a standalone or credentialed `terraform plan` or any `terraform apply`.

- [ ] **Step 3: Commit the reviewed infrastructure slice**

```bash
git add infra policy/terraform.rego tests/repository/test_terraform_contract.py
git commit -m "feat: add deployment-ready GCP infrastructure"
```

### Task 3: Execute and review the workload and observability plan

**Files:**
- Create/modify: files listed in `2026-09-01-gke-assessment-workloads-observability.md`
- Test: workload, MCI/MCS, image, Grafana, SQL, and Kind contract tests

**Interfaces:**
- Consumes: the exact Terraform outputs listed in the infrastructure plan.
- Produces: two regional workload overlays, configuration-cluster traffic overlays, three dashboards, bounded SQL, and a local readiness drill.

- [ ] **Step 1: Execute every workload-plan checkbox with TDD**

Use one fresh implementation worker per task and resolve public image digests before committing manifests. Network-dependent digest resolution and scans are account-free but must never be represented as GCP validation.

- [ ] **Step 2: Run the workload account-free gate**

```bash
make test-k8s
make test-observability
```

Expected: both app overlays render with three replicas, every workload image matches `policy/images.yaml`, MCI fields and HTTP/HTTPS staging pass, all dashboard and SQL contracts pass, and no `Gateway`, `HTTPRoute`, or `ServiceExport` baseline object is rendered.

- [ ] **Step 3: Run the controlled Kind drill when Docker is available**

```bash
make test-kind
```

Expected: App A and App B each reach three Ready replicas; the failure overlay makes App A unready and removes Ready endpoints; restoring the healthy overlay recovers three Ready replicas. The report labels this local Kubernetes evidence, not GKE/MCI evidence.

- [ ] **Step 4: Commit the reviewed workload slice**

```bash
git add k8s observability policy/images.yaml policy/kubernetes.rego tests
git commit -m "feat: add multi-cluster workloads and observability"
```

### Task 4: Execute and review the delivery and documentation plan

**Files:**
- Create/modify: files listed in `2026-09-01-gke-assessment-delivery-documentation.md`
- Move without semantic edits: `docs/requirments.md` to `docs/requirements/assessment-source.md`
- Test: workflow, script, documentation, traceability, and evidence contracts

**Interfaces:**
- Consumes: Terraform output names, manifest substitution tokens, validation commands, dashboards, and SQL from Tasks 2-3.
- Produces: safe scripts, protected future workflows, complete documentation, and one top-level account-free gate.

- [ ] **Step 1: Execute every delivery-plan checkbox with TDD**

The workflow parser tests must fail before workflows are added and must prove full-SHA Action pins, least permissions, manual cloud mutation, typed teardown confirmation, and one shared deployer identity.

- [ ] **Step 2: Preserve and normalize the assessment source path**

Run after the new path has been created by the plan:

```bash
cmp docs/requirments.md docs/requirements/assessment-source.md
```

Expected: byte-for-byte equality before removing the misspelled copy from the working tree. This proves the source requirements were moved, not rewritten.

- [ ] **Step 3: Run the delivery account-free gate**

```bash
make test-repository
make docs-check
```

Expected: script fake-command tests, workflow security assertions, internal links, ADR inventory, traceability rows, and evidence statuses all pass without GCP credentials.

- [ ] **Step 4: Commit the reviewed delivery slice**

```bash
git add .github .editorconfig .gitignore .python-version Makefile README.md pyproject.toml requirements-dev.lock scripts tools docs
git add -u docs/requirments.md
git commit -m "feat: add secure delivery automation and assessment documentation"
```

### Task 5: Run the complete account-free integration gate

**Files:**
- Verify: the complete repository
- Generate ignored evidence: `artifacts/validate/`

**Interfaces:**
- Consumes: every preceding deliverable.
- Produces: reproducible account-free evidence and a machine-readable summary with no live claims.

- [ ] **Step 1: Start with the repository contract tests**

```python
def test_cloud_mutation_is_manual_and_oidc_only(repository):
    validate = repository.workflow("validate.yml")
    deploy = repository.workflow("deploy.yml")
    teardown = repository.workflow("teardown.yml")
    assert validate.permissions == {"contents": "read"}
    assert "id-token" not in validate.raw
    assert deploy.triggers == {"workflow_dispatch"}
    assert teardown.triggers == {"workflow_dispatch"}
    assert deploy.service_accounts == {"${{ vars.GCP_DEPLOYER_SERVICE_ACCOUNT }}"}
    assert teardown.service_accounts == {"${{ vars.GCP_DEPLOYER_SERVICE_ACCOUNT }}"}
```

Run:

```bash
python3 -m pytest tests/repository -q
```

Expected: PASS.

- [ ] **Step 2: Run every deterministic check**

```bash
make validate-offline
```

Expected: Python tests, Terraform tests with cached providers, Kustomize rendering, schema/policy checks, dashboard validation, SQL lint, shell lint, YAML lint, and documentation checks pass. If a required cache is absent, the command reports the exact `make tools` prerequisite instead of silently skipping.

- [ ] **Step 3: Run network-dependent account-free checks**

```bash
make validate-network
```

Expected: tool checksums, Docker Hub digest resolution, and vulnerability scans pass. Trivy fails the build for a fixed Critical vulnerability; fixed High findings are reported and require an explicit reviewed exception entry with image digest, CVE, owner, rationale, and expiry date.

- [ ] **Step 4: Run the complete orchestrator**

```bash
make validate
```

Expected: exit 0 and `artifacts/validate/summary.json` reports `verified-account-free` only for checks actually run. All GCP, MCI, live BigQuery, live Grafana, DNS, and TLS rows remain `deployment-evidence-pending`.

- [ ] **Step 5: Scan for secrets, placeholders, and malformed whitespace**

```bash
git diff --check
grep -RInE 'TBD|TO[DO]|CHANGEME|example-secret|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' \
  --exclude-dir=.git --exclude-dir=.terraform --exclude-dir=.tools --exclude-dir=artifacts .
```

Expected: no match in implementation artifacts. Historical assessment wording and plan prose may be excluded explicitly by path if the scan reports them.

### Task 6: Independent review and completion handoff

**Files:**
- Review: all files changed since the approved design commit
- Update after verification: `docs/evidence/status.md`

**Interfaces:**
- Consumes: passing integrated checks and diff.
- Produces: reviewed repository ready for a future OIDC bootstrap and deployment, but not deployed.

- [ ] **Step 1: Invoke the verification workflow**

Read and follow `superpowers:verification-before-completion`. Re-run its required commands from fresh output; do not rely on earlier summaries.

- [ ] **Step 2: Invoke independent code review**

Read and follow `superpowers:requesting-code-review`. The reviewer must compare the diff with all 20 design-spec sections, all companion-plan constraints, and `docs/requirements/traceability.md`.

- [ ] **Step 3: Resolve every blocking review finding through TDD**

For each accepted finding, add or tighten a failing test, run it to prove the gap, make the smallest correction, and re-run the relevant subsystem plus `make validate`.

- [ ] **Step 4: Commit verification metadata**

```bash
git add docs/evidence/status.md
git commit -m "test: record account-free verification status"
```

- [ ] **Step 5: Invoke the branch-finishing workflow**

Read and follow `superpowers:finishing-a-development-branch`. Present integration choices without merging, pushing, deploying, or changing GitHub settings unless the user separately authorizes those actions.

## Completion Definition

Implementation is complete only when all three companion plans are checked, `make validate` passes from fresh output, independent review has no blocking findings, live evidence remains honestly pending, and the only future prerequisites are a suitable GCP account/project, one human ADC bootstrap, repository-level OIDC variables/environments, and optional owned DNS for HTTPS.
