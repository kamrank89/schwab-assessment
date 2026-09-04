# Permanent Cluster Administration and Private Grafana Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give one GitHub-variable-configured Google user permanent Connect Gateway `cluster-admin` access to both assessment clusters and loopback-only access to the live Grafana UI.

**Architecture:** Foundation Terraform owns Gateway IAM and the secret-scoped password grant, then publishes the validated email through platform remote state. The existing renderer installs exact-user Gateway impersonation and Kubernetes `cluster-admin` bindings in both clusters; a local helper creates an ephemeral Connect Gateway kubeconfig and forwards only `127.0.0.1:3000` to the internal Grafana Service.

**Tech Stack:** Terraform 1.15.9, Google provider 7.42.0, GitHub Actions repository variables, Bash, Kustomize 5.8.1, Kubernetes RBAC, GKE Fleet Connect Gateway, Secret Manager, kubectl.

**Spec:** `docs/superpowers/specs/2026-09-03-permanent-cluster-admin-grafana-access-design.md`

## Global Constraints

- `GCP_CLUSTER_ADMIN_EMAIL` is the single operator input; its value must never be committed to Git.
- The configured principal receives permanent `roles/gkehub.gatewayReader`, `roles/gkehub.gatewayAdmin`, and secret-level `roles/secretmanager.secretAccessor` only.
- Both clusters bind the exact configured Google user to the built-in Kubernetes `cluster-admin` ClusterRole and allow the Connect agent to impersonate only that user plus the existing deployer identity.
- Grafana remains `ClusterIP` and is never added to MCI, a public LoadBalancer, DNS, or an externally routable listener.
- Local forwarding binds only `127.0.0.1:3000`, runs in the foreground, and uses a mode-0600 temporary kubeconfig removed by traps.
- CI and repository scripts never retrieve, print, persist, or upload the Grafana password, access tokens, or kubeconfig content.
- Every new cluster-scoped Kubernetes grant has an explicit teardown deletion path.
- Do not change application routing, workload identity, application permissions, or the deployment service account's existing grants.

## File Structure

- Modify `infra/foundation/variables.tf`: validate the required operator email input.
- Create `infra/foundation/operator_iam.tf`: own the two Gateway roles and one secret-scoped accessor grant.
- Modify `infra/foundation/outputs.tf`: publish the normalized operator email.
- Modify `infra/platform/locals.tf`: consume the foundation operator output.
- Modify `infra/platform/outputs.tf`: publish the operator email to deployment and verification.
- Create `k8s/access/common/operator-cluster-admin.yaml`: bind the rendered user to `cluster-admin`.
- Modify `k8s/access/common/gateway-impersonation.yaml`: allow Connect Gateway to impersonate the rendered operator.
- Modify `k8s/access/common/kustomization.yaml`: include the operator binding in both regional access overlays.
- Modify `scripts/render-manifests.sh`: accept, validate, and render `--cluster-admin-email`.
- Modify `scripts/deploy.sh`: validate workflow configuration, pass the Terraform input, enforce output equality, and render the operator.
- Modify `scripts/verify.sh`: enforce output equality, render the operator, and inspect exact live bindings without recording the email.
- Modify `.github/workflows/deploy.yml`: expose the repository variable and Terraform input to every privileged deploy/verification job.
- Modify `.github/workflows/teardown.yml`: provide the Terraform input needed for foundation destruction.
- Modify `scripts/teardown.sh`: remove the operator ClusterRoleBinding from both surviving clusters.
- Create `scripts/access-grafana.sh`: provide fail-closed, ephemeral, loopback-only live access.
- Modify `docs/observability/grafana.md`: document the approved local access and password flow.
- Modify `docs/operations/verification.md`: replace the former no-human-access boundary with the exact supported procedure.
- Modify `docs/security/iam-and-secrets.md`: document the permanent administrator and its revocation boundary.
- Modify `docs/setup/github.md`: document initial configuration of the repository variable.
- Modify `docs/setup/bootstrap.md`: distinguish the 13 generated variables from the additional operator variable.
- Modify `README.md`: document the required post-bootstrap operator-variable step.

---

### Task 1: Add the Terraform operator identity and IAM contract

**Files:**

- Modify: `infra/foundation/variables.tf`
- Create: `infra/foundation/operator_iam.tf`
- Modify: `infra/foundation/outputs.tf`
- Modify: `infra/platform/locals.tf`
- Modify: `infra/platform/outputs.tf`

**Interfaces:**

- Consumes: Terraform string variable `cluster_admin_email` containing a bare Google user email.
- Produces: foundation and platform string output `cluster_admin_email`; project IAM for Gateway Reader/Admin; secret-level access to `grafana-admin`.

- [ ] **Step 1: Add the validated foundation input**

Append this variable to `infra/foundation/variables.tf`:

```hcl
variable "cluster_admin_email" {
  description = "Google user email receiving permanent Connect Gateway and Kubernetes cluster-admin access."
  type        = string

  validation {
    condition = can(regex(
      "^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$",
      lower(trimspace(var.cluster_admin_email)),
    ))
    error_message = "cluster_admin_email must be a valid bare Google user email."
  }
}
```

- [ ] **Step 2: Add narrowly scoped Google IAM resources**

Create `infra/foundation/operator_iam.tf`:

```hcl
locals {
  cluster_admin_email  = lower(trimspace(var.cluster_admin_email))
  cluster_admin_member = "user:${local.cluster_admin_email}"
}

resource "google_project_iam_member" "cluster_admin_gateway" {
  for_each = toset([
    "roles/gkehub.gatewayAdmin",
    "roles/gkehub.gatewayReader",
  ])

  project = local.project_id
  role    = each.value
  member  = local.cluster_admin_member
}

resource "google_secret_manager_secret_iam_member" "cluster_admin_grafana" {
  project   = local.project_id
  secret_id = google_secret_manager_secret.grafana_admin.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.cluster_admin_member
}
```

- [ ] **Step 3: Publish the normalized output through both state contracts**

Append to `infra/foundation/outputs.tf`:

```hcl
output "cluster_admin_email" {
  description = "The Google user email authorized for permanent cluster administration."
  value       = local.cluster_admin_email
}
```

Add this attribute to `local.foundation` in `infra/platform/locals.tf`:

```hcl
cluster_admin_email = tostring(local.foundation_outputs.cluster_admin_email)
```

Append to `infra/platform/outputs.tf`:

```hcl
output "cluster_admin_email" {
  description = "The Google user email authorized for permanent cluster administration."
  value       = local.foundation.cluster_admin_email
}
```

- [ ] **Step 4: Format and validate Terraform**

Run:

```bash
.tools/bin/terraform fmt -recursive infra
for root in infra/bootstrap infra/foundation infra/platform; do
  .tools/bin/terraform -chdir="${root}" init -backend=false
  .tools/bin/terraform -chdir="${root}" validate
done
```

Expected: every root reports `Success! The configuration is valid.` and no account or remote state is accessed.

- [ ] **Step 5: Commit the Terraform contract**

```bash
git add infra/foundation/variables.tf infra/foundation/operator_iam.tf \
  infra/foundation/outputs.tf infra/platform/locals.tf infra/platform/outputs.tf
git commit -m "feat: manage permanent cluster administrator IAM"
```

---

### Task 2: Render exact-user Connect Gateway and cluster-admin authorization

**Files:**

- Create: `k8s/access/common/operator-cluster-admin.yaml`
- Modify: `k8s/access/common/gateway-impersonation.yaml`
- Modify: `k8s/access/common/kustomization.yaml`
- Modify: `scripts/render-manifests.sh`

**Interfaces:**

- Consumes: renderer option `--cluster-admin-email EMAIL` and token `${ASSESSMENT_CLUSTER_ADMIN_EMAIL}`.
- Produces: `ClusterRoleBinding/assessment-operator-cluster-admin` in both clusters and exact-user Connect Gateway impersonation.

- [ ] **Step 1: Run the renderer contract check and observe the expected failure**

Run the existing renderer with all required fixture values plus the new option:

```bash
./scripts/render-manifests.sh \
  --project-id assessment-507423 \
  --project-number 222518988972 \
  --deployer-email assessment-deployer@assessment-507423.iam.gserviceaccount.com \
  --app-a-gsa-email app-a-runtime@assessment-507423.iam.gserviceaccount.com \
  --grafana-gsa-email grafana-runtime@assessment-507423.iam.gserviceaccount.com \
  --global-ipv4-address 192.0.2.10 \
  --cloud-armor-policy-name assessment-edge-policy \
  --bigquery-dataset assessment_logs \
  --cluster-admin-email operator@example.com \
  --tls-certificate-name ""
```

Expected before implementation: exit 1 with `Unknown argument: --cluster-admin-email`.

- [ ] **Step 2: Add the exact-user ClusterRoleBinding**

Create `k8s/access/common/operator-cluster-admin.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: assessment-operator-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: ${ASSESSMENT_CLUSTER_ADMIN_EMAIL}
```

Add `operator-cluster-admin.yaml` to `k8s/access/common/kustomization.yaml`.

- [ ] **Step 3: Extend exact-user Gateway impersonation**

In `k8s/access/common/gateway-impersonation.yaml`, make `resourceNames` contain exactly:

```yaml
resourceNames:
  - ${ASSESSMENT_DEPLOYER_EMAIL}
  - ${ASSESSMENT_CLUSTER_ADMIN_EMAIL}
```

Do not add groups, domains, wildcard resources, or `system:masters`.

- [ ] **Step 4: Extend the renderer interface and validation**

In `scripts/render-manifests.sh`:

- add `--cluster-admin-email EMAIL` to usage;
- initialize `ASSESSMENT_CLUSTER_ADMIN_EMAIL=""`;
- parse the option with `require_value`;
- validate it with this Bash expression:

```bash
[[ "${ASSESSMENT_CLUSTER_ADMIN_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
  die "--cluster-admin-email is not a valid Google user email."
ASSESSMENT_CLUSTER_ADMIN_EMAIL="${ASSESSMENT_CLUSTER_ADMIN_EMAIL,,}"
```

- add this replacement to the existing `sed` invocation:

```bash
-e "s|\${ASSESSMENT_CLUSTER_ADMIN_EMAIL}|${ASSESSMENT_CLUSTER_ADMIN_EMAIL}|g"
```

Keep the existing unresolved-token checks unchanged so a missed token fails closed.

- [ ] **Step 5: Re-run the renderer check and inspect behavior**

Run the Step 1 command again. Expected: exit 0.

Then run:

```bash
for overlay in .generated/k8s/access/us-central1 .generated/k8s/access/us-east1; do
  .tools/bin/kustomize build "${overlay}" | .tools/bin/kubeconform \
    -strict -summary -ignore-missing-schemas
done

grep -RIn 'operator@example.com' .generated/k8s/access
grep -RIn '\${ASSESSMENT_CLUSTER_ADMIN_EMAIL}' .generated/k8s && exit 1 || true
```

Expected: both overlays validate; the rendered user appears in each common access overlay; no unresolved token remains.

- [ ] **Step 6: Commit rendered authorization support**

```bash
git add k8s/access/common/operator-cluster-admin.yaml \
  k8s/access/common/gateway-impersonation.yaml \
  k8s/access/common/kustomization.yaml scripts/render-manifests.sh
git commit -m "feat: render permanent cluster administrator RBAC"
```

---

### Task 3: Propagate and verify the GitHub repository variable

**Files:**

- Modify: `.github/workflows/deploy.yml`
- Modify: `.github/workflows/teardown.yml`
- Modify: `scripts/deploy.sh`
- Modify: `scripts/verify.sh`

**Interfaces:**

- Consumes: GitHub repository variable `GCP_CLUSTER_ADMIN_EMAIL` and platform output `.cluster_admin_email.value`.
- Produces: `TF_VAR_cluster_admin_email`, renderer argument `--cluster-admin-email`, and live exact-binding verification.

- [ ] **Step 1: Add workflow environment propagation**

For every privileged job in `.github/workflows/deploy.yml` (`prepare-https-to-http`, `deploy-foundation`, `deploy-platform-and-workloads`, `smoke-verification`, `hpa-drill`, and `failover-drill`), add:

```yaml
GCP_CLUSTER_ADMIN_EMAIL: ${{ vars.GCP_CLUSTER_ADMIN_EMAIL }}
TF_VAR_cluster_admin_email: ${{ vars.GCP_CLUSTER_ADMIN_EMAIL }}
```

Add the same two entries to the teardown job environment in `.github/workflows/teardown.yml`. Do not add them to credential-free `validate.yml`.

- [ ] **Step 2: Pass the input through Terraform and workload rendering**

In `scripts/deploy.sh`, make `validate_common_environment` require and validate `GCP_CLUSTER_ADMIN_EMAIL`. Add this foundation plan argument:

```bash
-var="cluster_admin_email=${GCP_CLUSTER_ADMIN_EMAIL}"
```

In both `transition_https_to_http` and `deploy_workloads`, read:

```bash
cluster_admin_email="$(jq -er '.cluster_admin_email.value |
  select(type == "string" and test("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$"))' \
  <<<"${platform_json}")"
[[ "${cluster_admin_email}" == "${GCP_CLUSTER_ADMIN_EMAIL,,}" ]] ||
  die "Platform cluster administrator email differs from GCP_CLUSTER_ADMIN_EMAIL."
```

Pass `--cluster-admin-email "${cluster_admin_email}"` to both renderer invocations.

- [ ] **Step 3: Propagate and inspect the binding during verification**

In `scripts/verify.sh`:

- require and validate `GCP_CLUSTER_ADMIN_EMAIL` in `validate_environment`;
- read `.cluster_admin_email.value` in `initialize_context`;
- require exact lowercase equality with the workflow value;
- pass `--cluster-admin-email` to `render-manifests.sh`;
- after obtaining both Gateway kubeconfigs, inspect `ClusterRoleBinding/assessment-operator-cluster-admin` and `ClusterRole/assessment-deployer-gateway-impersonation` in each cluster.

Use `jq` to require exactly one binding subject with kind `User` and the configured email, `roleRef.name == "cluster-admin"`, and an impersonation `resourceNames` array containing both the deployer and operator emails. Record only:

```text
cluster=<cluster-name> operator_cluster_admin=configured gateway_impersonation=configured
```

Never record the email.

- [ ] **Step 4: Validate scripts and workflows**

Run:

```bash
bash -n scripts/*.sh
.tools/bin/shellcheck scripts/*.sh
.tools/bin/actionlint .github/workflows/*.yml
git diff --check
```

Expected: exit 0 with no ShellCheck, workflow, or whitespace errors.

- [ ] **Step 5: Commit propagation and verification**

```bash
git add .github/workflows/deploy.yml .github/workflows/teardown.yml \
  scripts/deploy.sh scripts/verify.sh
git commit -m "feat: propagate cluster administrator configuration"
```

---

### Task 4: Make teardown symmetric for cluster-scoped access

**Files:**

- Modify: `scripts/teardown.sh`

**Interfaces:**

- Consumes: fixed Kubernetes object name `assessment-operator-cluster-admin`.
- Produces: deletion of the operator ClusterRoleBinding in each surviving cluster before Terraform destruction.

- [ ] **Step 1: Run the cleanup coverage check and observe the expected failure**

Run:

```bash
test "$(grep -Fc 'clusterrolebinding/assessment-operator-cluster-admin' scripts/teardown.sh)" -eq 2
```

Expected before implementation: exit 1 because neither regional cleanup branch includes the binding.

- [ ] **Step 2: Add operator binding deletion to both cluster branches**

In both the secondary and primary cluster cleanup commands near the existing Gateway impersonation deletion, include:

```bash
clusterrolebinding/assessment-operator-cluster-admin
```

Keep `--ignore-not-found --wait=true --timeout=5m` so repeated or resumed teardown remains safe.

- [ ] **Step 3: Validate teardown syntax and exact coverage**

Run:

```bash
bash -n scripts/teardown.sh
.tools/bin/shellcheck scripts/teardown.sh
test "$(grep -Fc 'clusterrolebinding/assessment-operator-cluster-admin' scripts/teardown.sh)" -eq 2
```

Expected: syntax/static analysis pass and the fixed binding appears exactly once in each regional deletion branch.

- [ ] **Step 4: Commit teardown symmetry**

```bash
git add scripts/teardown.sh
git commit -m "fix: remove operator access during teardown"
```

---

### Task 5: Add the fail-closed local Grafana access helper

**Files:**

- Create: `scripts/access-grafana.sh`

**Interfaces:**

- Consumes: `--project-id ID`, `--operator-email EMAIL`; active `gcloud` user; fixed primary membership and Grafana Service.
- Produces: foreground loopback forward `127.0.0.1:3000 -> service/grafana:3000`; no files after exit.

- [ ] **Step 1: Run the helper interface check and observe the expected failure**

Run:

```bash
scripts/access-grafana.sh --help
```

Expected before implementation: exit 127 because the helper does not exist.

- [ ] **Step 2: Implement argument and identity validation**

Create `scripts/access-grafana.sh` with `set -euo pipefail`, `set +x`, and `umask 077`. Support only:

```text
Usage: access-grafana.sh --project-id ID --operator-email EMAIL
```

Validate the project ID with the repository's existing project regex and the operator with the Task 2 email regex. Require `gcloud`, `kubectl`, `mktemp`, `install`, `chmod`, and `rm`. Obtain the active account with:

```bash
active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
[[ "${active_account,,}" == "${operator_email,,}" ]] ||
  die "The active gcloud account does not match --operator-email."
```

Reject empty or multi-line results by applying the email validation to `active_account` before equality.

- [ ] **Step 3: Implement ephemeral Gateway access and cleanup**

Use:

```bash
temporary_parent="${TMPDIR:-/tmp}"
temporary_parent="${temporary_parent%/}"
temporary_root="$(mktemp -d "${temporary_parent}/gke-assessment-grafana.XXXXXX")"
chmod 0700 "${temporary_root}"
kubeconfig="${temporary_root}/gateway.kubeconfig"
install -m 0600 /dev/null "${kubeconfig}"
cleanup() {
  if [[ -n "${temporary_root}" &&
        "${temporary_root}" == "${temporary_parent}"/gke-assessment-grafana.* &&
        -d "${temporary_root}" ]]; then
    rm -rf -- "${temporary_root}"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
```

Then obtain primary membership credentials without printing kubeconfig content:

```bash
KUBECONFIG="${kubeconfig}" gcloud container fleet memberships get-credentials \
  gke-assessment-us-central1 --location=global --project="${project_id}" --quiet >/dev/null
chmod 0600 "${kubeconfig}"
```

- [ ] **Step 4: Verify authorization/readiness and start only a loopback forward**

Require these checks:

```bash
[[ "$(KUBECONFIG="${kubeconfig}" kubectl auth can-i '*' '*' --all-namespaces)" == "yes" ]] ||
  die "The active account is not cluster-admin through Connect Gateway."
KUBECONFIG="${kubeconfig}" kubectl -n observability wait \
  --for=condition=Available deployment/grafana --timeout=60s >/dev/null
```

Print only the local URL and username, then keep the forward in the foreground:

```bash
printf '%s\n' 'Grafana URL: http://127.0.0.1:3000' 'Username: admin'
KUBECONFIG="${kubeconfig}" kubectl -n observability port-forward \
  --address=127.0.0.1 service/grafana 3000:3000
```

Do not retrieve the password, background the process, accept arbitrary addresses, or persist kubeconfig content.

- [ ] **Step 5: Validate the helper without cloud access**

Run:

```bash
bash -n scripts/access-grafana.sh
.tools/bin/shellcheck scripts/access-grafana.sh
scripts/access-grafana.sh --help

set +e
output="$(scripts/access-grafana.sh --project-id invalid --operator-email operator@example.com 2>&1)"
status=$?
set -e
test "${status}" -ne 0
grep -F 'Invalid project ID' <<<"${output}"
```

Expected: syntax/static analysis and help pass; invalid input fails before any cloud call.

- [ ] **Step 6: Commit the helper**

```bash
git add scripts/access-grafana.sh
git commit -m "feat: add private Grafana access helper"
```

---

### Task 6: Document permanent access, password handling, and revocation

**Files:**

- Modify: `docs/observability/grafana.md`
- Modify: `docs/operations/verification.md`
- Modify: `docs/security/iam-and-secrets.md`
- Modify: `docs/setup/github.md`
- Modify: `docs/setup/bootstrap.md`
- Modify: `README.md`

**Interfaces:**

- Consumes: repository variable and helper interfaces from Tasks 3 and 5.
- Produces: exact operator setup, access, verification, and revocation instructions without committing the operator email.

- [ ] **Step 1: Update GitHub setup**

Document the required local variable and explicit 14th repository-variable command without placing its value in Git:

```bash
read -rp 'Cluster administrator Google email: ' GCP_CLUSTER_ADMIN_EMAIL
gh variable set GCP_CLUSTER_ADMIN_EMAIL \
  --repo kamrank89/schwab-assessment \
  --body "${GCP_CLUSTER_ADMIN_EMAIL}"
unset GCP_CLUSTER_ADMIN_EMAIL
```

State in `docs/setup/github.md`, `docs/setup/bootstrap.md`, and `README.md` that bootstrap still configures its 13 generated/fixed variables, this explicit command adds the required operator variable, this is a permanent super-user grant, and changing the variable requires another reviewed Deploy run.

- [ ] **Step 2: Replace the old Grafana no-access boundary**

In `docs/observability/grafana.md` and `docs/operations/verification.md`, document:

```bash
read -rp 'Cluster administrator Google email: ' GCP_CLUSTER_ADMIN_EMAIL
./scripts/access-grafana.sh \
  --project-id assessment-507423 \
  --operator-email "${GCP_CLUSTER_ADMIN_EMAIL}"
```

In a separate local terminal, retrieve the password directly from Secret Manager:

```bash
gcloud secrets versions access latest \
  --secret=grafana-admin \
  --project=assessment-507423
```

State explicitly: username is `admin`; browse to `http://127.0.0.1:3000`; stop the forward with Ctrl-C; never paste the password or dashboard data into tickets, logs, artifacts, or Git.

- [ ] **Step 3: Document identity and revocation semantics**

In `docs/security/iam-and-secrets.md`, add the permanent operator to the identity diagram and enumerate Gateway Reader/Admin, exact-user `cluster-admin` in both clusters, and secret-scoped Grafana accessor. State that `cluster-admin` includes all Secrets and authorization mutation inside both clusters.

Document revocation as either:

- running the supported teardown, which removes Kubernetes and Terraform-owned IAM grants; or
- replacing the GitHub variable with a reviewed successor identity and running Deploy, then verifying the old exact subject is absent from both bindings and IAM policies before treating revocation as complete.

- [ ] **Step 4: Validate documentation and commit**

Run:

```bash
git diff --check
test -n "${GCP_CLUSTER_ADMIN_EMAIL}"
grep -RInF -- "${GCP_CLUSTER_ADMIN_EMAIL}" docs infra k8s scripts .github && exit 1 || true
```

Expected: no whitespace failures and no operator email committed.

Commit:

```bash
git add docs/observability/grafana.md docs/operations/verification.md \
  docs/security/iam-and-secrets.md docs/setup/github.md docs/setup/bootstrap.md README.md
git commit -m "docs: explain private Grafana administrator access"
```

---

### Task 7: Run complete account-free verification and configure GitHub

**Files:**

- Verify all files from Tasks 1-6.
- External configuration: GitHub repository variable `GCP_CLUSTER_ADMIN_EMAIL`.

**Interfaces:**

- Consumes: completed implementation and the approved operator email held only in the shell environment.
- Produces: a validated commit series and configured non-secret GitHub variable; no cloud or Kubernetes mutation.

- [ ] **Step 1: Run the complete repository validation**

```bash
make validate
git diff --check
find . -type f \( -name '*.tfplan' -o -name '*.tfstate' -o -name '*.pem' \
  -o -name '*service-account*.json' -o -name 'kubeconfig*' \) \
  -not -path './.git/*' -not -path '*/.terraform/*' -print
```

Expected: `make validate` and `git diff --check` exit 0; the sensitive-artifact search prints nothing.

- [ ] **Step 2: Verify the committed privacy boundary**

```bash
test -n "${GCP_CLUSTER_ADMIN_EMAIL}"
git grep -nF -- "${GCP_CLUSTER_ADMIN_EMAIL}" && exit 1 || true
git status --short
```

Expected: no email match and a clean worktree.

- [ ] **Step 3: Configure the approved GitHub variable**

With the approved email already held locally in `GCP_CLUSTER_ADMIN_EMAIL`, run:

```bash
gh variable set GCP_CLUSTER_ADMIN_EMAIL \
  --repo kamrank89/schwab-assessment \
  --body "${GCP_CLUSTER_ADMIN_EMAIL}"
gh variable list --repo kamrank89/schwab-assessment | awk '$1 == "GCP_CLUSTER_ADMIN_EMAIL" { found=1 } END { exit !found }'
unset GCP_CLUSTER_ADMIN_EMAIL
```

Expected: the variable name is present. Do not print its value.

- [ ] **Step 4: Review the implementation diff and commit any final plan-only corrections**

```bash
git log --oneline --decorate -8
git status --short
```

Expected: the task commits are present and the worktree is clean. Do not amend or squash without explicit user direction.

---

### Task 8: Deploy and verify live access after review

**Files:**

- No repository changes.
- External systems: GitHub Actions, GCP IAM, Secret Manager IAM, both GKE clusters, local workstation.

**Interfaces:**

- Consumes: pushed implementation commits and configured GitHub variable.
- Produces: permanent live access and a loopback-only Grafana session.

- [ ] **Step 1: Push through the repository's normal review path**

Push the implementation commits only after user review. Do not rewrite history or bypass branch protections.

- [ ] **Step 2: Dispatch the ordinary Deploy workflow**

```bash
gh workflow run deploy.yml --repo kamrank89/schwab-assessment --ref main \
  -f https_to_http_transition=false \
  -f run_hpa_drill=false \
  -f run_failover_drill=false
```

This is a cloud/Kubernetes mutation and requires explicit authorization at execution time. Wait for deployment and smoke verification to finish; do not claim access from a queued or partial run.

- [ ] **Step 3: Verify the human API identity from the workstation**

```bash
gcloud auth login
read -rp 'Cluster administrator Google email: ' GCP_CLUSTER_ADMIN_EMAIL
test "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "${GCP_CLUSTER_ADMIN_EMAIL}" | tr '[:upper:]' '[:lower:]')"
```

Expected: exact identity equality without service-account impersonation.

- [ ] **Step 4: Open the private Grafana session**

```bash
./scripts/access-grafana.sh \
  --project-id assessment-507423 \
  --operator-email "${GCP_CLUSTER_ADMIN_EMAIL}"
```

Expected: the helper confirms `cluster-admin`, reports an Available Grafana Deployment, and forwards `127.0.0.1:3000` in the foreground. Retrieve the password in a separate local terminal using the documented Secret Manager command and log in as `admin`.

- [ ] **Step 5: Verify and end the local session**

While the foreground helper remains open, run this from a separate local terminal:

```bash
curl --silent --show-error --fail http://127.0.0.1:3000/api/health >/dev/null
```

Expected: exit 0. Inspect the three provisioned dashboards in the UI, then stop the forward with Ctrl-C and unset the email variable. Do not record the password, tokens, kubeconfig, raw dashboard query results, or unredacted screenshots.
