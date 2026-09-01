# GKE Assessment Delivery and Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide reproducible local validation, safe one-time bootstrap and future deployment/verification/teardown automation, credential-minimal GitHub workflows, and enough tested documentation for the user to explain and defend every design decision.

**Architecture:** Python libraries implement parsing, rendering, plan fingerprinting, evidence redaction, and repository policy; thin Bash entrypoints enforce operator guards and call pinned command-line tools. Pull requests run a credential-free validation workflow. Future infrastructure mutation is manual and staged—foundation plan/apply, then platform plan/apply/workloads/verification—through protected GitHub environments using one OIDC-federated `assessment-deployer`; teardown is separately confirmed and leaves bootstrap trust intact.

**Tech Stack:** Python 3.13.15, pytest, PyYAML, jsonschema, SQLFluff, yamllint, Bash/ShellCheck, Make, GitHub Actions, GitHub CLI, Google GitHub Actions auth/setup-gcloud, Terraform/Kustomize/Kind/Trivy toolchain.

**Spec:** `docs/superpowers/specs/2026-08-31-gke-assessment-platform-design.md`

## Global Constraints

- Implementation and account-free validation must not authenticate to GCP or deploy anything.
- The future one-time bootstrap is the only human-ADC phase; after it completes, GitHub stores non-secret identifiers only and uses OIDC/WIF.
- `validate.yml` runs on pull requests and pushes to `main` with only `contents: read`; it has no `id-token`, secrets, privileged event, plan, apply, or cloud mutation.
- `deploy.yml` and `teardown.yml` are `workflow_dispatch` only, reject non-`main` refs, use protected environments, and impersonate the same `${{ vars.GCP_DEPLOYER_SERVICE_ACCOUNT }}`.
- Foundation and platform plan/apply are separate stages so an initial deployment never assumes foundation remote state already exists.
- Saved Terraform plans are job-local, mode 0600, removed by traps, and never uploaded. Reviewers receive a redacted structural summary and deterministic fingerprint.
- A production approval follows each plan. `production-plan` is branch-restricted but need not require an approver before a read-only plan; `production` and `teardown` require reviewers and prevent self-review.
- Teardown requires the exact project ID plus the literal prefix `DESTROY ` followed by that same ID, deletes MCI/workloads first, then platform, then foundation, and retains bootstrap state/WIF.
- Pin every `uses:` reference to a 40-character commit SHA. Do not use `pull_request_target` or mutable Action tags.
- Install every non-runner tool from an exact version and verify its release checksum; no installer accepts `latest`.
- Treat Docker Hub digest and vulnerability checks as account-free but network-dependent, never as live GCP evidence.
- Allow evidence statuses only `verified-account-free`, `deployment-evidence-pending`, `verified-live`, and `not-applicable`.
- Preserve the supplied assessment source byte-for-byte when moving it to `docs/requirements/assessment-source.md`.
- Documentation must distinguish fact, design decision, inference, limitation, future recommendation, and deployment evidence.

---

## File Structure

```text
.
├── .editorconfig
├── .gitignore
├── .python-version
├── .github/
│   ├── CODEOWNERS
│   ├── dependabot.yml
│   └── workflows/{validate,deploy,teardown}.yml
├── Makefile
├── pyproject.toml
├── requirements-dev.lock
├── scripts/
│   ├── __init__.py
│   ├── validate.py
│   ├── bootstrap.sh
│   ├── configure-github.sh
│   ├── deploy.sh
│   ├── verify.sh
│   ├── teardown.sh
│   ├── install-tools.sh
│   └── lib/{__init__.py,command.py,validation.py,render.py,plan_fingerprint.py,evidence.py,repository.py,workflows.py}
├── tools/{versions.env,checksums.sha256}
├── tests/
│   ├── conftest.py
│   ├── unit/{test_command.py,test_render.py,test_plan_fingerprint.py,test_evidence.py}
│   └── repository/{test_action_pins.py,test_workflow_security.py,test_script_contracts.py,test_documentation_contract.py,test_traceability_contract.py,test_evidence_status.py,test_toolchain_lock.py}
├── docs/
│   ├── requirements/{assessment-source.md,traceability.md}
│   ├── architecture/{overview.md,customer-traffic-flow.md,observability-flow.md,identity-and-delivery.md,terraform-state-boundaries.md,teardown-sequence.md}
│   ├── adr/{0001-terraform-state-boundaries.md,0002-gke-autopilot.md,0003-mci-mcs-baseline-and-gateway-migration.md,0004-github-actions-push-delivery.md,0005-single-assessment-deployer-identity.md,0006-public-images-and-digest-allowlist.md,0007-secret-manager-and-workload-identity.md,0008-self-hosted-grafana.md,0009-observability-data-sources.md,0010-binary-authorization-deferral.md,0011-cost-controls.md}
│   ├── setup/{prerequisites.md,bootstrap.md,github-configuration.md,deployment.md,dns-and-tls.md,verification.md,teardown.md}
│   ├── ci-cd/{workflow-security.md,toolchain.md,github-environments.md}
│   ├── security/{threat-model.md,iam-matrix.md,supply-chain-policy.md,limitations.md}
│   ├── observability/{bigquery-schema.md,grafana-provisioning.md,dashboard-interpretation.md}
│   ├── operations/{rollout-and-rollback.md,scaling.md,regional-failover.md,secret-rotation.md,disaster-recovery.md,dashboard-use.md}
│   ├── troubleshooting/{readiness-probe-drill.md,incident-template.md}
│   ├── evidence/{checklist.md,status.md,deployment-evidence-template.md,residual-resource-check.md}
│   ├── cost-model.md
│   ├── interview-guide.md
│   └── references.md
└── README.md
```

### Task 1: Repository harness and checksum-locked tools

**Files:**
- Create: `.editorconfig`, `.gitignore`, `.python-version`, `pyproject.toml`, `requirements-dev.lock`, `Makefile`
- Create: `scripts/{__init__.py,validate.py,install-tools.sh}`, `scripts/lib/{__init__.py,command.py,validation.py}`
- Create: `tools/{versions.env,checksums.sha256}`
- Create: `tests/conftest.py`, `tests/unit/test_command.py`, `tests/repository/test_toolchain_lock.py`

**Interfaces:**
- Produces `CommandResult(argv:tuple[str,...], returncode:int, stdout:str, stderr:str)`, `run_checked(argv:Sequence[str], cwd:Path|None=None, env:Mapping[str,str]|None=None, redact:Iterable[str]=()) -> CommandResult`, and `require_tools(names:Sequence[str]) -> None`.
- Produces immutable `Violation(code:str, path:str, message:str)` and a `runtime_values` pytest fixture containing non-secret syntactically valid examples for the eight allowed renderer tokens.
- Produces Make targets `venv`, `tools`, `test-unit`, `test-terraform`, `test-k8s`, `test-observability`, `test-kind`, `test-repository`, `docs-check`, `validate-offline`, `validate-network`, `validate`, and the guarded human-only `bootstrap` entry point.

- [ ] **Step 1: Write failing command/toolchain tests**

```python
from pathlib import Path
import re

from scripts.lib.command import run_checked


def test_run_checked_captures_output_and_redacts_secret(tmp_path):
    result = run_checked(
        ["python3", "-c", "print('token=sensitive-value')"],
        redact=["sensitive-value"],
    )
    assert result.returncode == 0
    assert "sensitive-value" not in result.stdout
    assert "[REDACTED]" in result.stdout


def test_every_tool_has_an_exact_version_and_two_linux_checksums():
    versions = Path("tools/versions.env").read_text().splitlines()
    assert all("latest" not in line.lower() for line in versions)
    assert all(re.fullmatch(r"[A-Z0-9_]+=[0-9][0-9A-Za-z.+_-]*", line) for line in versions if line and not line.startswith("#"))
    checksums = Path("tools/checksums.sha256").read_text()
    for arch in ("linux-amd64", "linux-arm64"):
        assert arch in checksums
```

- [ ] **Step 2: Run and observe import/file failures**

Run: `python3 -m pytest tests/unit/test_command.py tests/repository/test_toolchain_lock.py -q`

Expected: FAIL because the helper and lock files do not exist.

- [ ] **Step 3: Add exact Python environment**

`.python-version` contains `3.13.15`, and the workflow's pinned setup-python action reads that file. `pyproject.toml` configures pytest paths and strict markers. Generate `requirements-dev.lock` with hashes for exact releases of pytest, PyYAML, jsonschema, yamllint, and SQLFluff using:

```bash
python3 -m pip install pip-tools==7.6.1
python3 -m piptools compile --generate-hashes --resolver=backtracking --output-file=requirements-dev.lock pyproject.toml
python3 -m pip install --require-hashes -r requirements-dev.lock
```

The committed lock contains no editable VCS or URL dependency.

- [ ] **Step 4: Lock the repository tool versions**

`tools/versions.env` defines exact versions for Terraform 1.15.9, kubectl 1.35.8, Kustomize 5.8.1, Kubeconform 0.7.0, Kind 0.31.0, TFLint 0.64.0, Conftest 0.68.2, Trivy 0.72.0, crane 0.21.7, ShellCheck 0.11.0, yq 4.53.2, and gcloud 582.0.0. `tools/checksums.sha256` records Linux AMD64/ARM64 and Darwin AMD64/ARM64 where publishers provide those assets.

- [ ] **Step 5: Implement the verified installer**

`install-tools.sh` uses `set -Eeuo pipefail`, detects only supported OS/architecture pairs, downloads into a `mktemp -d` directory, verifies the matching committed SHA-256 before extraction, installs into ignored `.tools/bin`, prints versions, and cleans the temporary directory with a trap. It rejects a missing checksum, redirect to an unapproved host, unsupported platform, and any version string equal to `latest`.

- [ ] **Step 6: Implement command redaction and Make targets**

`run_checked` uses `subprocess.run(..., shell=False, text=True, capture_output=True)` and never logs environment values. Make uses `.tools/bin` and `.venv/bin` explicitly and does not silently skip missing binaries. `validate-offline` calls deterministic tests only; `validate-network` resolves/scans images; `validate` calls both plus Kind.

`make bootstrap` is deliberately outside every validation dependency. It accepts only the named non-secret Make variables `PROJECT_ID`, `STATE_BUCKET`, `GITHUB_REPOSITORY`, `GITHUB_REPOSITORY_ID`, `GITHUB_OWNER_ID`, and `CREATE_PROJECT`; creation mode additionally requires `BILLING_ACCOUNT` and permits at most one of `FOLDER_ID` or `ORGANIZATION_ID`. Omitting both supports a personal/no-organization account and triggers an explicit governance warning. The recipe rejects missing or inconsistent combinations before execution and passes each value to `scripts/bootstrap.sh` as a separately quoted argv element; it accepts no free-form shell flag string. A dry-run test proves `make bootstrap` is never reached by `make validate`, and invoking it without the required variables fails before any cloud command.

- [ ] **Step 7: Verify and commit the harness**

```bash
python3 -m pytest tests/unit/test_command.py tests/repository/test_toolchain_lock.py -q
bash -n scripts/install-tools.sh
make -n validate
```

Expected: PASS; the dry run contains no cloud plan/apply or gcloud mutation.

```bash
git add .editorconfig .gitignore .python-version Makefile pyproject.toml requirements-dev.lock scripts tools tests/conftest.py tests/unit/test_command.py tests/repository/test_toolchain_lock.py
git commit -m "build: add reproducible validation toolchain"
```

### Task 2: Safe rendering, plan fingerprints, and evidence records

**Files:**
- Create: `scripts/lib/{render.py,plan_fingerprint.py,evidence.py,repository.py}`
- Create: `tests/unit/{test_render.py,test_plan_fingerprint.py,test_evidence.py}`
- Extend: `scripts/validate.py`

**Interfaces:**
- Produces `render_text(text:str, values:Mapping[str,str]) -> str`, restricted to the eight tokens in the master plan.
- Produces `canonical_plan_summary(plan_json:Mapping) -> PlanSummary`, `PlanSummary.fingerprint -> str`, and `PlanSummary.to_markdown() -> str`.
- Produces `EvidenceRecord(check_id:str, status:EvidenceStatus, command:tuple[str,...], started_at:str, commit_sha:str, artifact_paths:tuple[str,...], note:str)` and `write_evidence(records, out_dir)`.

- [ ] **Step 1: Write failing renderer tests**

```python
def test_renderer_substitutes_only_declared_runtime_tokens():
    text = "${GCP_PROJECT_ID} $__timeFilter(timestamp) $cluster"
    rendered = render_text(text, {"GCP_PROJECT_ID": "project-123"})
    assert rendered == "project-123 $__timeFilter(timestamp) $cluster"


def test_renderer_fails_on_an_unresolved_runtime_token():
    with pytest.raises(ValueError, match="unresolved"):
        render_text("${UNAPPROVED_VALUE}", {})
```

- [ ] **Step 2: Write failing plan-fingerprint tests**

Use two Terraform JSON documents with identical resource changes but different ordering and sensitive values. Assert equal 64-hex fingerprints, absence of values in Markdown, and a changed fingerprint when a non-sensitive planned value or action changes.

- [ ] **Step 3: Write failing evidence tests**

Assert only the four allowed statuses serialize, UTC timestamps end in `Z`, live evidence requires workflow run URL plus artifact, and `verified-account-free` rejects a command containing `terraform apply`, `gcloud ... create`, or a non-Kind `kubectl apply` context.

- [ ] **Step 4: Run and observe missing helpers**

Run: `python3 -m pytest tests/unit/test_render.py tests/unit/test_plan_fingerprint.py tests/unit/test_evidence.py -q`

Expected: FAIL on imports.

- [ ] **Step 5: Implement exact behavior**

Fingerprint input retains resource address, provider name, action list, replacement reason, import flag, unknown markers, and non-sensitive planned values. Paths marked by `before_sensitive` or `after_sensitive` are replaced with the constant `[SENSITIVE]`; variables, provider configuration, and private fields are dropped before canonical JSON hashing with sorted keys/separators. Human Markdown retains only addresses/actions/counts and never prints planned values. Evidence redaction masks Authorization headers, access tokens, passwords, private keys, and caller-supplied redaction values before writing JSON/Markdown.

- [ ] **Step 6: Add validate subcommands**

`validate.py` exposes `terraform`, `manifests`, `images`, `dashboards`, `sql`, `docs`, `kind`, and `all`, each with required `--out`. It runs commands through `run_checked`, creates no output outside the supplied directory, and returns nonzero if a required check is unavailable or fails.

- [ ] **Step 7: Verify and commit**

```bash
python3 -m pytest tests/unit/test_render.py tests/unit/test_plan_fingerprint.py tests/unit/test_evidence.py -q
python3 scripts/validate.py --help
```

Expected: PASS and all subcommands listed.

```bash
git add scripts/lib scripts/validate.py tests/unit
git commit -m "feat: add safe render and evidence primitives"
```

### Task 3: Bootstrap, GitHub configuration, deployment, verification, and teardown scripts

**Files:**
- Create: `scripts/{bootstrap.sh,configure-github.sh,deploy.sh,verify.sh,teardown.sh}` and `scripts/lib/live_drills.py`
- Create: `tests/unit/test_live_drills.py`, `tests/repository/test_script_contracts.py`
- Create test fixtures dynamically under pytest temporary directories; do not commit fake credentials.

**Interfaces:**
- `bootstrap.sh`: human ADC bootstrap and state migration.
- `configure-github.sh`: non-secret variables/environments.
- `deploy.sh`: `plan|apply|workloads|initialize-secrets` operations.
- `verify.sh`: `preflight|all|hpa-drill|regional-failover-drill` evidence; live drills require explicit opt-in and bounded restoration.
- `teardown.sh`: confirmed reverse-order cleanup excluding bootstrap.

- [ ] **Step 1: Write a fake-command harness and failing guard tests**

```python
def fake_command(bin_dir: Path, name: str, log: Path):
    path = bin_dir / name
    path.write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' \"$0 $*\" >> {log}\n")
    path.chmod(0o755)


def test_teardown_rejects_wrong_confirmation_before_mutation(fake_path, command_log):
    result = subprocess.run([
        "bash", "scripts/teardown.sh",
        "--project-id", "assessment-123",
        "--state-bucket", "assessment-123-tfstate",
        "--confirmation", "DESTROY wrong-project",
    ], env=fake_path, text=True, capture_output=True)
    assert result.returncode != 0
    assert command_log.read_text() == ""
```

Add tests that `make bootstrap` maps only its named variables and rejects missing inputs before mutation; bootstrap rejects CI and missing ADC; plan/apply pass one identical state bucket to backend and remote-state configuration; apply rejects a local caller without `--allow-local-apply`; apply rejects a fingerprint mismatch; workloads rejects unresolved `${...}` and a null certificate only when HTTPS is enabled; cluster access requires the GKE auth plugin, ADC mode, explicit project/location, and an ephemeral kubeconfig; workload delivery waits for the Secret Manager CSI API on both clusters before either regional apply and polls both Fleet MCS and MCI with bounded timeouts before the first MCS/MCI apply; configure-GitHub writes no secret; failover rejects an absent or mismatched disruption confirmation before mutation; every drill registers cleanup before its first mutable or background operation; and teardown has no path to bootstrap destroy. Unit-test the load generator with a local fake HTTP server, fixed duration and concurrency ceilings, response-body discard, and deterministic cancellation.

- [ ] **Step 2: Run and prove scripts are absent**

Run: `python3 -m pytest tests/unit/test_live_drills.py tests/repository/test_script_contracts.py -q`

Expected: FAIL with the missing live-drill module and script paths.

- [ ] **Step 3: Implement one-time bootstrap**

`bootstrap.sh` requires project ID, repository owner/name, immutable owner/repository IDs, state bucket, and either `--existing-project` or billing plus optional parent creation inputs. The named `make bootstrap` variables map one-to-one to those flags and are the documented entry point. The script requires `gcloud auth application-default print-access-token` to succeed with both output streams suppressed so the token is never logged, rejects `GITHUB_ACTIONS=true`, initializes bootstrap locally without a backend block, applies only after an interactive typed project confirmation, copies `backend.tf.example` to ignored `infra/bootstrap/backend.generated.tf`, migrates state to `prefix=bootstrap`, writes mode-0600 `.generated/bootstrap-outputs.json`, and calls `configure-github.sh` unless explicitly skipped. There is no key-creation command.

Before the first apply, bootstrap performs read-only checks for the selected ADC/quota project, target project existence versus creation mode, billing linkage or Billing Account User access, parent Project Creator access when applicable, state-bucket name availability, required API usability, GitHub numeric IDs matching the repository, and absence of committed Google credentials. It reports organization policies or quota failures that could block two regional Autopilot clusters, external IAM-authorized DNS endpoints, global load balancing, or MCI; it never weakens a policy automatically.

- [ ] **Step 4: Implement non-secret GitHub setup**

`configure-github.sh` verifies `gh auth status`, creates/enables `production-plan`, `production`, and `teardown` environments through the GitHub API, and sets only:

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
GCP_DEV_PRINCIPALS_JSON
GCP_OPS_PRINCIPALS_JSON
GCP_SRE_PRINCIPALS_JSON
```

The last six receive safe HTTP-first defaults `false`, `false`, `false`, `[]`, `[]`, and `[]`. Optional `GCP_DNS_NAME`, `GCP_DNS_ZONE_NAME`, and `GCP_DNS_ZONE_DNS_NAME` variables are omitted until the operator owns a domain; the workflow passes them only when non-empty. The third value is required only when Terraform creates a public zone and is the trailing-dot DNS suffix containing the certificate hostname. It prints exact repository-admin follow-up for `main` branch protection, required `validate` check, CODEOWNERS, production/teardown reviewers, prevent-self-review, and deployment-branch restrictions because reviewer identities are a human governance choice. Without `gh`, it prints exact `gh variable set` commands from non-secret output values.

- [ ] **Step 5: Implement plan/apply with job-local plans**

`deploy.sh plan --stack foundation|platform` initializes the selected state prefix, passes the same required bucket as `TF_VAR_terraform_state_bucket` for remote-state lookup, creates a mode-0600 plan in `$RUNNER_TEMP`, converts it to JSON, writes only redacted Markdown and fingerprint, then removes plan/JSON on exit. For foundation it maps the checked-in HTTP defaults plus the optional GitHub variables to typed `TF_VAR_enable_https`, `TF_VAR_manage_dns`, `TF_VAR_create_dns_zone`, DNS hostname/zone resource name/zone suffix only when non-empty, and JSON-decoded team principal lists; platform consumes no independent copies of those settings. `apply` recomputes the plan and fingerprint, compares with `--expected-fingerprint` using constant-time string comparison, and applies that fresh local saved plan immediately. It fails outside GitHub Actions unless `--allow-local-apply` is supplied by an authenticated operator.

- [ ] **Step 6: Implement secret initialization and workload delivery**

`initialize-secrets` adds a version only when `app-a-demo` or `grafana-admin` has no enabled version. App A receives 32 random bytes encoded with newline-free `openssl base64 -A`; the Grafana password uses 32 random bytes encoded as newline-free hexadecimal so it is printable and safe for file-based authentication. Values stream directly from `openssl rand` through encoding into `gcloud secrets versions add --data-file=-` and never enter argv/output/artifacts.

`workloads` creates a mode-0600 temporary kubeconfig with `mktemp`, registers its removal trap immediately, and for each new cluster runs the exact initial credential command with that file as `KUBECONFIG`:

```bash
KUBECONFIG="$ephemeral_kubeconfig" \
  gcloud container clusters get-credentials "$cluster_name" \
    --location "$region" \
    --project "$GCP_PROJECT_ID" \
    --dns-endpoint
```

Through that IAM-aware DNS endpoint it creates the two labeled namespaces and applies only the committed Connect Gateway impersonation and namespace Role/RoleBinding objects (including MCI RBAC on the configuration cluster). It proves the exact deployer can perform the expected namespaced verbs. Before either regional overlay is applied, it uses each cluster context to poll with a bounded timeout until API discovery serves `secretproviderclasses.secrets-store.csi.x-k8s.io` at `secrets-store.csi.x-k8s.io/v1` and `csidriver/secrets-store-gke.csi.k8s.io` exists. A terminal error or timeout fails before workload mutation. It then removes the bootstrap kubeconfig, creates a fresh mode-0600 ephemeral Connect Gateway kubeconfig, and runs `KUBECONFIG="$gateway_kubeconfig" gcloud container fleet memberships get-credentials "$membership_name" --location global --project "$GCP_PROJECT_ID"` for both exact memberships before all remaining delivery. This resolves the unavoidable first-gateway-RBAC bootstrap without a public IP endpoint, static credential, or human follow-up.

The script renders regional and HTTP overlays from the seven non-null common values (`GCP_PROJECT_ID`, project number, global IP, Armor policy, both workload GSA emails, and dataset). It applies regional overlays to their matching clusters and waits for their rollouts. Before any multi-cluster object, it polls both `gcloud container fleet multi-cluster-services describe --project "$GCP_PROJECT_ID" --format=json` and `gcloud container fleet ingress describe --project "$GCP_PROJECT_ID" --format=json` with bounded timeouts until both features report `resourceState.state` as `ACTIVE` and each command reports exactly the two required global memberships with `state.code` equal to `OK`. Missing, extra, pending, or failed membership state is not accepted. A terminal error or timeout fails before any MCS/MCI object is applied; this accounts for asynchronous feature and CRD enablement on a first deployment. It then applies HTTP MCI only to the configuration membership. Only when HTTPS is enabled does it require a non-null `TLS_CERTIFICATE_NAME`, add the eighth substitution, prove DNS resolves to the reserved IP, apply the TLS-attachment overlay, wait for the Compute certificate to become `ACTIVE`, smoke-test HTTPS, and apply the redirect overlay. It waits for every rollout/reconciliation gate and never substitutes an empty string for a required token. Teardown keeps the gateway impersonation policy until all other Gateway-driven Kubernetes cleanup is complete, then uses a fresh ephemeral DNS-endpoint kubeconfig to remove the gateway policy and namespaces without asking the gateway to delete its own authorization.

- [ ] **Step 7: Implement live verification without optimistic skips**

`verify.sh all` fails unless it proves both Fleet memberships healthy; three Ready replicas per app/cluster; MCI/MCS resources reconciled; backend health is non-empty; required BigQuery log classes/tables appear and bounded queries execute; Grafana health, three dashboards, and both datasource health checks succeed; no Google key file is mounted. Every BigQuery data query first performs a dry run and then executes with UTC timestamp parameters plus `--maximum_bytes_billed=1073741824`; schema metadata discovery is the documented bounded-cost exception. It proves the App A CSI path exists and is non-empty without reading its content and App B has no secret volume.

For IAM, it distinguishes inheritance correctly: each secret-level policy contains only its expected runtime accessor binding, while the project policy contains the documented `assessment-deployer` Secret Manager Admin grant needed for initialization and no other Terraform-managed secret-access principal. It never claims the runtime GSA is the only effective accessor. A live negative test executes a non-echoing shell inside one App A Pod: it obtains its metadata-server token entirely inside the container, accesses `app-a-demo` with the response discarded to `/dev/null`, then requires access to `grafana-admin` to fail. Neither token nor either secret response crosses `kubectl exec`, enters argv, or appears in evidence; only the two exit classifications are recorded. Image compatibility validation proves the pinned App A image contains the required shell, `envsubst`, and HTTPS-capable `wget` before this contract is accepted.

For authenticated Grafana API checks it reads `grafana-admin` into a mode-0600 temporary netrc file, registers the value with GitHub masking without logging it, keeps it out of argv/artifacts, and deletes it through a trap. With HTTPS disabled, HTTP `/app-a` and `/app-b` must each return `200`. With HTTPS enabled, HTTP must return the configured redirect status and location while HTTPS `/app-a` and `/app-b` each return `200`; certificate or redirect failure is fatal. Evidence is redacted and timestamped.

`scripts.lib.live_drills` supplies a bounded Python HTTP load generator that uses standard-library clients, caps concurrency and duration, discards bodies, records status and error counts only, and always stops workers on cancellation. `verify.sh hpa-drill --region us-central1` first requires three Ready Pods for each app and Connect Gateway streaming support, then opens one loopback-only `kubectl port-forward` to each of those six Pods using OS-selected local ports. This distributes load across all baseline Pods and deliberately bypasses the public load balancer's per-client Cloud Armor throttle; the drill is HPA evidence, not ingress-capacity evidence. It registers termination of every port-forward and load worker before starting load, drives both apps for at most ten minutes, and requires each selected-cluster HPA to exceed desired replica count three plus the corresponding Deployment to reach that desired Ready count. It then stops load and waits at most ten additional minutes for both HPAs and Deployments to return to the three-replica floor. A streaming, scale-up, or restoration timeout is failure evidence, not a skip.

`verify.sh regional-failover-drill --failed-region REGION --confirmation "FAILOVER REGION"` accepts only one of the two known regions and requires that exact confirmation. It registers a restoration trap first, records both clusters healthy, deletes only App A and App B Deployments in the chosen region, and waits until that region has no Ready app endpoints while the other region retains three Ready replicas for both apps. Because MCI and NEG health propagation is asynchronous, it next polls the underlying backend-health view with a bounded timeout until the failed region's backends are unhealthy or absent and the surviving region's backends are healthy; a terminal error or convergence timeout fails before traffic assertions. Only then does it require five new-connection requests to each global route to succeed. Those successes demonstrate service from the surviving region after the load balancer has observed the failure, rather than relying on optimistic timing. The trap reapplies the committed rendered regional overlay, waits for three Ready replicas and Ready endpoints for both apps, and requires MCI backend health to return healthy even on interruption or assertion failure. Evidence records the failed and surviving regions, pre-failure state, endpoint absence, bounded backend-health convergence, HTTP results, and restored state without response bodies or credentials. This is a controlled application-data-plane exercise, not a destructive cluster-outage claim.

- [ ] **Step 8: Implement guarded teardown**

`teardown.sh` requires main GitHub context unless an explicit local override, project equality, state bucket, and exact confirmation. Through Connect Gateway it deletes MCI/MCS/FrontendConfig/BackendConfig, waits with a bounded timeout for managed LB/backend cleanup, and removes cluster workloads. It then creates a new mode-0600 temporary kubeconfig, registers cleanup immediately, and for each exact cluster/region pair runs the same `KUBECONFIG="$ephemeral_kubeconfig" gcloud container clusters get-credentials "$cluster_name" --location "$region" --project "$GCP_PROJECT_ID" --dns-endpoint` contract before removing the gateway impersonation/RBAC objects and namespaces. Only then does it destroy platform and foundation.

Residual discovery inventories clusters, Fleet features/memberships, forwarding rules, target proxies, URL maps, backend services, health checks, NEGs, MCI-generated and Terraform firewall rules, addresses, SSL certificates/policies, Cloud Armor policies, VPC/subnets/routers/NAT, managed DNS zones/records, logging sinks, BigQuery datasets, secret containers, runtime/node service accounts, and the `foundation`/`platform` state prefixes. It proves each current non-bootstrap state contains zero managed resources; versioned empty-state history is expected recovery metadata, not a live cloud-resource leak. Foundation APIs deliberately use `disable_on_destroy = false`, so these read-only discovery calls remain available after destroy. The report labels enabled APIs and their Google-managed service agents, the empty project Fleet container, retained state history, bootstrap bucket/prefix, WIF pool/provider, deployer service account/project roles, and bootstrap APIs as expected non-workload state. Any other assessment-owned resource fails the residual check. The script refuses any bootstrap destroy target, prefix, or directory.

- [ ] **Step 9: Verify scripts and commit**

```bash
python3 -m pytest tests/unit/test_live_drills.py tests/repository/test_script_contracts.py -q
shellcheck scripts/*.sh
bash -n scripts/*.sh
```

Expected: PASS; fake-command logs prove rejected paths mutate nothing.

```bash
git add scripts tests/unit/test_live_drills.py tests/repository/test_script_contracts.py
git commit -m "feat: add guarded platform lifecycle scripts"
```

### Task 4: Credential-free validation and protected lifecycle workflows

**Files:**
- Create: `.github/workflows/{validate,deploy,teardown}.yml`, `.github/CODEOWNERS`, `.github/dependabot.yml`
- Create: `scripts/lib/workflows.py`
- Create: `tests/repository/{test_action_pins.py,test_workflow_security.py}`

**Interfaces:**
- Consumes Make targets and script CLIs from Tasks 1-3 plus Terraform/Kubernetes plan contracts.
- Produces exactly three workflows and immutable Action references.

- [ ] **Step 1: Write failing Action-pin tests**

```python
USES = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")


def test_every_external_action_is_immutable():
    for path in Path(".github/workflows").glob("*.yml"):
        workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
        for reference in collect_uses(workflow):
            if reference.startswith("./"):
                continue
            assert USES.fullmatch(reference), f"mutable Action reference: {reference}"
```

- [ ] **Step 2: Write failing permission/trigger tests**

Assert validate triggers only PR/push-to-main/manual, top permission is exactly contents read, and raw text has no `id-token`, `secrets.`, `pull_request_target`, `terraform plan`, or `terraform apply`. Assert deploy/teardown trigger only dispatch, guard main, use the expected environments, set `id-token: write` only in authenticated jobs, share one service-account variable, use the same non-cancelling concurrency group, and give every Google auth step exact `workload_identity_provider`, `service_account`, and `audience: https://iam.googleapis.com/${{ vars.GCP_WIF_PROVIDER }}` inputs. Require `run_live_drills` to be a boolean defaulting to false and require both guarded drill commands only behind that exact condition. Assert no uploaded path contains a Terraform plan.

- [ ] **Step 3: Run and prove workflows are absent**

Run: `python3 -m pytest tests/repository/test_action_pins.py tests/repository/test_workflow_security.py -q`

Expected: FAIL because no workflows exist.

- [ ] **Step 4: Add approved immutable Action references**

Use these full pins only:

```text
actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065
google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093
google-github-actions/setup-gcloud@aa5489c8933f4cc7a4f7d45035b3b1440c9c10db
actions/upload-artifact@65462800fd760344b1a7b4382951275a0abb4808
```

Dependabot opens reviewed GitHub Actions and pip update PRs; it never auto-merges.

- [ ] **Step 5: Implement `validate.yml`**

PR/push-to-main/manual workflow, `permissions: contents: read`, pinned checkout/setup-python/upload, `pip --require-hashes`, `make tools`, `make validate`, and upload only `artifacts/validate/` with 30-day retention. Kind runs on a Docker-capable hosted runner. It has no GCP auth action, environment, secret, OIDC, Terraform plan, or deployment command.

- [ ] **Step 6: Implement staged `deploy.yml`**

Use concurrency `gke-assessment-production`, `cancel-in-progress: false`, and this dependency graph:

```text
validate-account-free
  -> plan-foundation [production-plan]
  -> apply-foundation [production]
  -> plan-platform [production-plan]
  -> apply-platform-deliver-verify [production]
  -> live-drills [production, conditional]
```

Each authenticated job has only `contents: read` and `id-token: write`, authenticates with provider `${{ vars.GCP_WIF_PROVIDER }}`, service account `${{ vars.GCP_DEPLOYER_SERVICE_ACCOUNT }}`, and explicit audience `https://iam.googleapis.com/${{ vars.GCP_WIF_PROVIDER }}`. It requests a one-hour service-account access token and creates an ephemeral ADC file. The pinned setup-gcloud Action installs gcloud 582.0.0 plus its matching `gke-gcloud-auth-plugin`; Kubernetes jobs set `USE_GKE_GCLOUD_AUTH_PLUGIN=True` and `gcloud config set container/use_application_default_credentials true` in an ephemeral Cloud SDK configuration before generating kubeconfigs. Parser tests require those inputs and settings. Plan jobs expose fingerprints and redacted summaries as job outputs/step summaries. Apply jobs recompute/compare before apply. The apply/deliver/verify job initializes missing secret versions, deploys through Connect Gateway, verifies, and uploads only redacted evidence.

A typed boolean `run_live_drills` dispatch input defaults to `false`. When explicitly true, a separate dependent `live-drills` job obtains a fresh OIDC/ADC session, runs `hpa-drill --region us-central1`, then runs `regional-failover-drill --failed-region us-east1 --confirmation "FAILOVER us-east1"`, and uploads its redacted restoration evidence. Separating the potentially long drills avoids relying on credentials minted before infrastructure reconciliation. A normal first deploy remains non-disruptive, while one explicit re-dispatch can collect the two additional evidence classes.

The workflow passes `TF_STATE_BUCKET` to every Terraform script call and maps the six defaulted configuration variables plus optional non-empty DNS variables into the script environment. Parser tests require the same mapping in plan and apply jobs so a reviewed plan cannot use different HTTPS, DNS, or team-IAM inputs from its apply.

- [ ] **Step 7: Implement `teardown.yml`**

Manual inputs `project_id` and `confirmation`; main/project/confirmation guards run before auth. Use environment `teardown`, the production concurrency group, the same WIF identity with the same explicit canonical audience, and `scripts/teardown.sh`. Upload only redacted residual-resource evidence. Bootstrap state and trust are explicitly excluded.

- [ ] **Step 8: Add CODEOWNERS and verify**

CODEOWNERS assigns `.github/workflows/`, `infra/`, `k8s/`, `policy/`, `scripts/`, and security/ADR docs to `@kamrank89`, matching the configured GitHub remote owner. `configure-github.sh` accepts a future `--codeowner` override if the repository is transferred before bootstrap.

Run:

```bash
python3 -m pytest tests/repository/test_action_pins.py tests/repository/test_workflow_security.py -q
yamllint .github/workflows .github/dependabot.yml
```

Expected: PASS.

```bash
git add .github scripts/lib/workflows.py tests/repository/test_action_pins.py tests/repository/test_workflow_security.py
git commit -m "ci: add keyless protected lifecycle workflows"
```

### Task 5: Requirements, architecture, ADRs, security, operations, and setup documentation

**Files:**
- Move unchanged: `docs/requirments.md` -> `docs/requirements/assessment-source.md`
- Create: every documentation file listed in the file structure except evidence files handled in Task 6
- Create: `tests/repository/{test_documentation_contract.py,test_traceability_contract.py}`

**Interfaces:**
- Produces traceability rows with columns `ID`, `Requirement`, `Implementation`, `Account-free test`, `Live verification`, `Evidence`, and `Status`.
- Produces stable requirement IDs `RQ-001` onward and ADR statuses `Accepted` or `Accepted for assessment; production migration recommended`.

- [ ] **Step 1: Write failing documentation inventory and link tests**

```python
def test_required_document_inventory_exists():
    missing = [path for path in REQUIRED_DOCS if not Path(path).is_file()]
    assert missing == []


def test_internal_markdown_links_resolve():
    for source, target in collect_internal_links(Path("docs")):
        assert target.exists(), f"{source} links to missing {target}"
```

- [ ] **Step 2: Write failing traceability tests**

Parse the Markdown table and require unique sequential `RQ-NNN` IDs, non-empty implementation/test/live/evidence cells, only allowed status values, and coverage tokens for project, VPC/NAT/flow logs/private access, both Autopilot regions, Fleet/MCI/MCS, both apps/four placements, three replicas/HPA/PDB, routing/failover, Cloud Armor, Secret Manager/WI, four BigQuery log classes, BigQuery, four overview panels, three dashboards, Terraform states, OIDC, workflows, troubleshooting, DNS/TLS, rollback, teardown, cost, Trace, Profiler, and Error Reporting.

- [ ] **Step 3: Run and prove the inventory is incomplete**

Run: `python3 -m pytest tests/repository/test_documentation_contract.py tests/repository/test_traceability_contract.py -q`

Expected: FAIL listing missing documents and traceability rows.

- [ ] **Step 4: Preserve the assessment source**

Copy the current bytes, verify with `cmp`, then remove only the misspelled copy:

```bash
cmp docs/requirments.md docs/requirements/assessment-source.md
```

The assessment source receives a short adjacent README/note, not edits inside the supplied text, explaining that it is source requirements rather than executable instructions.

- [ ] **Step 5: Write architecture and setup guides**

Use Mermaid diagrams for system topology, customer path, observability flow, identity/delivery, state boundaries, and teardown order. Setup guides contain exact named `make bootstrap` variables, bootstrap flags, every required/default/optional GitHub variable and its Terraform mapping, staged deployment, HTTP-first verification, optional DNS/certificate/redirect, live verification, opt-in HPA/failover drills with restoration, and teardown. They state that the checked-in/default configuration deploys HTTP with empty team lists, so after the one-time account/bootstrap trust step no source edit is required; DNS/TLS is an explicit later configuration change. Every command labels whether it is account-free, creates cost, generates load, deliberately removes a regional workload, reads protected data, or destroys resources.

The network documentation must distinguish Private Google Access from Private Service Access. Enable Private Google Access on both subnets because private nodes need Google APIs; do not create a producer peering allocation because this assessment has no managed producer service that consumes Private Service Access. Record the allocation/peering as a future prerequisite if Cloud SQL, Memorystore, or another supported private-service producer is introduced.

Explain why there are two workload subnets rather than artificial load-balancer and monitoring subnets: the global external Application Load Balancer/MCI proxies are Google-managed and do not consume a proxy-only subnet in this design, while Grafana is an internal pod workload in the primary cluster. A separate proxy-only subnet becomes relevant for regional managed-proxy load balancers, not this global MCI baseline.

The customer-traffic guide corrects the source document's generic ingress-controller hop for this selected implementation: the MCI controller is a reconciliation component that programs the global external Application Load Balancer and zonal NEGs; request data travels from the Google edge directly to healthy Pod endpoints through the VPC, not through a separately deployed NGINX or GKE Ingress proxy Pod. App A's NGINX process is the assessed application container, not an ingress controller.

- [ ] **Step 6: Write all eleven ADRs**

Each ADR contains Context, Decision, Consequences, Alternatives, Production evolution, and primary references. The single-identity ADR explicitly explains the assessment simplification, union-of-permissions limitation, compensating controls, and recommended planner/infrastructure/workload/teardown identity split. The MCI ADR includes exact migration: ServiceExport/ServiceImport, Gateway/HTTPRoute under a new hostname/IP, GCPBackendPolicy/HealthCheckPolicy, acceptance/failover/TLS tests, DNS shift, rollback window, then MCI removal.

- [ ] **Step 7: Write security and operations guides**

Threat model covers GitHub issuer multi-tenancy, malicious PRs, broad single identity, Terraform state, image and Grafana-plugin supply chain, public ingress, IAM-authorized external DNS control-plane endpoints, secrets, logs, Grafana admin access, and teardown. IAM matrix lists every human/pipeline/runtime principal and scope. Explain that IP endpoints remain disabled: the DNS endpoint is reachable so a hosted runner can perform the automated initial Gateway-RBAC bootstrap, but every request still authenticates and authorizes through Google IAM/GKE. Operations covers rollout/rollback, emergency `rollout undo` plus Git reconciliation, scaling, controlled failover, secret rotation, Grafana use, MCI config-cluster loss, state recovery, and data-plane versus reconciliation behavior. Explain that sampled VPC Flow Logs and NAT error logs stay in Cloud Logging but outside the cost-bounded BigQuery sink. In this non-Shared-VPC baseline the MCI controller manages the required health-check/firewall integration in the cluster project; its generated firewall rules are not falsely described as Terraform-owned or as having configurable rule logging. A future Shared VPC design must delegate firewall administration or pre-create the documented health-check rules in the host project.

The disaster-recovery guide states that both assessed apps are stateless and reconstructed from Terraform/Kustomize, GKE owns Autopilot control-plane recovery, and there is no database or Artifact Registry to back up in this baseline. It records Backup for GKE, owned image mirroring, and stateful-service backups as explicit production additions rather than claiming nonexistent etcd, database, or registry backup jobs.

- [ ] **Step 8: Write observability, cost, references, and interview guide**

Explain table materialization/schema drift, each SQL query, each panel, metadata auth inference requiring live smoke, Trace/Profiler absence of app instrumentation, Error Reporting dependency on compatible exceptions, and no fabricated values. Cost model includes the 12-backend-pod MCI minimum of about $36/month plus compute/LB/NAT/logging/BigQuery/DNS. Interview guide includes a five-minute walkthrough, each trade-off, likely objections, troubleshooting demo, costs, production evolution, and concise answers tied to ADRs.

- [ ] **Step 9: Verify and commit docs**

```bash
python3 -m pytest tests/repository/test_documentation_contract.py tests/repository/test_traceability_contract.py -q
python3 scripts/validate.py docs --out artifacts/docs
```

Expected: PASS with no broken internal links or uncovered acceptance item.

```bash
git add docs README.md tests/repository/test_documentation_contract.py tests/repository/test_traceability_contract.py
git add -u docs/requirments.md
git commit -m "docs: add assessment operations and decision record"
```

### Task 6: Honest evidence model, top-level README, and integrated validation

**Files:**
- Create: `docs/evidence/{checklist.md,status.md,deployment-evidence-template.md,residual-resource-check.md}`
- Create: `tests/repository/test_evidence_status.py`
- Finalize: `README.md`, `Makefile`, `scripts/validate.py`

**Interfaces:**
- Consumes every subsystem check ID and traceability row.
- Produces `artifacts/validate/summary.json`, `summary.md`, rendered manifests, dashboard inventory, SQL inventory, image reports, tool versions, and local drill evidence.

- [ ] **Step 1: Write the failing evidence-status test**

```python
ALLOWED = {"verified-account-free", "deployment-evidence-pending", "verified-live", "not-applicable"}


def test_evidence_statuses_are_honest_and_complete():
    rows = parse_status_table(Path("docs/evidence/status.md"))
    assert rows
    assert {row.status for row in rows} <= ALLOWED
    assert all(row.command and row.evidence_path for row in rows)
    for row in rows:
        if row.status == "verified-live":
            assert row.utc_timestamp.endswith("Z")
            assert re.fullmatch(r"[0-9a-f]{40}", row.commit_sha)
            assert row.workflow_url.startswith("https://github.com/")
            assert row.redaction_note
            assert row.artifact_path and ".." not in Path(row.artifact_path).parts


def test_initial_repository_has_no_unsubstantiated_live_claim():
    rows = parse_status_table(Path("docs/evidence/status.md"))
    assert all(row.status != "verified-live" or row.has_complete_live_record for row in rows)
```

- [ ] **Step 2: Run and observe the missing status file**

Run: `python3 -m pytest tests/repository/test_evidence_status.py -q`

Expected: FAIL reading `docs/evidence/status.md`.

- [ ] **Step 3: Create the evidence taxonomy**

Status rows cover every traceability requirement. Account-free rows cite exact Make/pytest commands and committed exports; cloud/Fleet/MCI/public endpoint/failover/HPA/live BQ/live Grafana/TLS/IAM/teardown rows are pending. The live template requires command, UTC timestamp, commit SHA, workflow URL, actor/reviewer, redaction note, result, and artifact path before a status may change to verified-live.

- [ ] **Step 4: Finalize the top-level operator path**

README begins with scope and honest deployment status, then the shortest safe path: `make venv`, `make tools`, `make validate`; review cost; run future bootstrap; configure environment reviewers; dispatch deployment; verify; collect evidence; dispatch teardown. It links architecture, traceability, ADRs, interview guide, and limitations and states clearly that implementation never deployed resources.

- [ ] **Step 5: Run every account-free gate**

```bash
make test-unit
make test-terraform
make test-k8s
make test-observability
make test-repository
make docs-check
make validate-network
make test-kind
make validate
```

Expected: all required checks pass from fresh output. `summary.json` records no GCP credential use and no verified-live row.

- [ ] **Step 6: Verify no plan/key/secret artifact exists**

```bash
find . -type f \( -name '*.tfplan' -o -name '*.pem' -o -name '*service-account*.json' -o -name 'kubeconfig*' \) -not -path './.git/*' -print
git diff --check
```

Expected: the find command prints nothing and whitespace check passes.

- [ ] **Step 7: Commit**

```bash
git add README.md Makefile scripts/validate.py docs/evidence tests/repository/test_evidence_status.py
git commit -m "test: add complete account-free evidence gate"
```

## Live-Only Boundary

The workflows and scripts are testable with fake commands and static parsers, but their cloud behavior remains unproven until an authorized future run. Before a GCP account, do not claim a Terraform plan/apply, state lock, cluster/Fleet readiness, Connect Gateway access, MCI health, public endpoint, failover, HPA response, BigQuery rows/schema, Grafana datasource/rendered values, secret mount, IAM denial, certificate, screenshot, teardown, or residual-resource result. The committed dashboard JSON satisfies the assessment's export alternative without fabricating a screenshot.
