# Permanent Cluster Administration and Private Grafana Access Design

## Context

The deployed assessment has two private GKE Autopilot clusters registered in one Fleet. Routine automation reaches their Kubernetes APIs through Connect Gateway, but the committed baseline authorizes only the GitHub deployment service account. Grafana runs only in `us-central1` behind a `ClusterIP` Service, and its random administrator password is stored in the `grafana-admin` Secret Manager secret.

The operator needs permanent Kubernetes API administration for both clusters and live Grafana dashboard access from a workstation. The approved Google identity is supplied outside Git through a repository variable. The operator explicitly selected the built-in Kubernetes `cluster-admin` role after reviewing that it permits every action on every current and future resource, including Secrets and authorization policy.

## Goals

- Manage the operator identity declaratively through the repository's existing Terraform, rendering, deployment, verification, and teardown paths.
- Authorize the configured operator email to use Connect Gateway and act as `cluster-admin` in both supported clusters.
- Grant that identity access to the Grafana administrator password at the individual-secret scope only.
- Keep Grafana private and expose it only on workstation loopback while an authenticated port-forward process is running.
- Fail closed when identity configuration, authentication, authorization, Fleet membership, or Grafana readiness is invalid.
- Avoid static service-account keys, persistent kubeconfigs, public Grafana routing, and credential material in Git, workflow logs, or artifacts.

## Non-goals

- Do not add Grafana to Multi Cluster Ingress, create a public LoadBalancer Service, or provide an internet-accessible Grafana URL.
- Do not add IAP, SSO, OAuth, new Grafana users, or a durable Grafana database.
- Do not grant the human identity project-wide Secret Manager access.
- Do not let CI retrieve or print the Grafana administrator password.
- Do not change application routing, application authorization, workload identities, or the existing deployment service account's permissions.

## Configuration Contract

The GitHub repository variable `GCP_CLUSTER_ADMIN_EMAIL` is the single operator input. It is non-secret configuration, but its value is not committed anywhere in Git history so the source remains reusable.

The deploy workflow maps the repository variable to both `GCP_CLUSTER_ADMIN_EMAIL` and Terraform input `TF_VAR_cluster_admin_email`. Foundation Terraform validates it as a Google user email and exports it as a non-sensitive output. Platform remote state imports the value and republishes it as part of the platform output contract. The workload deployment reads the platform output, requires it to equal the workflow variable, and passes it to `render-manifests.sh` as `--cluster-admin-email`.

The renderer validates the email again and replaces only the approved `${ASSESSMENT_CLUSTER_ADMIN_EMAIL}` token. A missing, malformed, or inconsistent value stops before Kubernetes mutation.

## Google Cloud IAM

Foundation Terraform grants the configured `user:<email>` principal:

- `roles/gkehub.gatewayReader` on project `assessment-507423`, to obtain Connect Gateway credentials;
- `roles/gkehub.gatewayAdmin` on project `assessment-507423`, including the streaming permission required for `kubectl port-forward`; and
- `roles/secretmanager.secretAccessor` on the `grafana-admin` secret only.

No project-wide Container Admin, Secret Manager Admin, or service-account impersonation role is added for the operator. Kubernetes authorization, rather than a redundant project-wide Container role, supplies cluster administration after Gateway authentication.

## Kubernetes Authorization

The shared access overlay applied to both clusters adds two exact-subject policies:

1. A Connect Gateway impersonation rule permits the `gke-connect/connect-agent-sa` ServiceAccount to impersonate only the configured operator email, alongside the existing deployment-service-account rule.
2. A dedicated ClusterRoleBinding binds the configured operator email to the built-in `cluster-admin` ClusterRole.

The binding names are fixed and owned by Kustomize so repeated deployment is idempotent. No group, domain, wildcard subject, `system:masters` membership, or service-account impersonation is used.

## Private Grafana Access Flow

A repository helper, `scripts/access-grafana.sh`, accepts the project ID and expected operator email through explicit options or narrowly named environment variables. It performs the following sequence:

1. Verify required commands and require the active `gcloud` account to equal the expected email exactly.
2. Create a private temporary directory and mode-0600 kubeconfig, with cleanup traps for normal exit and termination signals.
3. Obtain credentials for Fleet membership `gke-assessment-us-central1` through Connect Gateway.
4. Verify that the active identity can perform an all-resources/all-verbs authorization check and that `deployment/grafana` is Available in namespace `observability`.
5. Start `kubectl port-forward` from `service/grafana` to `127.0.0.1:3000` only.
6. Keep forwarding in the foreground and delete the temporary kubeconfig when the process stops.

The script prints the local URL `http://127.0.0.1:3000` and the administrator username `admin`. It does not access or print the password. Documentation gives the operator a local-only `gcloud secrets versions access` command for `grafana-admin`; the value must not be pasted into issues, workflow input, logs, or repository files.

Grafana remains a `ClusterIP`, its NetworkPolicy remains unchanged, and there is no externally routable listener. Closing the helper process ends workstation access even though IAM and RBAC remain permanent.

## Failure and Cleanup Behavior

- Missing or malformed `GCP_CLUSTER_ADMIN_EMAIL` fails the privileged workflow before Terraform planning.
- A foundation/platform email mismatch fails workload rendering before Kubernetes apply.
- A wrong active local account, missing Gateway permission, failed credential generation, failed `cluster-admin` authorization check, absent Grafana Deployment, or unavailable Grafana replica stops the helper without starting the forward.
- Cleanup traps remove only the helper's validated temporary directory and kubeconfig.
- Teardown explicitly deletes the operator ClusterRoleBinding and the Gateway impersonation objects from each surviving cluster before platform destruction. Foundation destruction removes project IAM and the secret-scoped accessor grant.
- Changing or revoking the operator requires a reviewed repository-variable change followed by the appropriate deploy or teardown lifecycle; ad hoc grants are not part of the supported path.

## Verification

Account-free verification will cover:

- Terraform formatting and validation for the new input, IAM grants, and output propagation;
- workflow linting and early validation of the GitHub variable;
- renderer rejection of missing, malformed, or unresolved operator values;
- rendered Kubernetes schema validation and exact-user impersonation/`cluster-admin` bindings in both regional overlays;
- shell syntax and ShellCheck for deployment, teardown, rendering, and the local helper;
- teardown coverage for every new cluster-scoped resource; and
- the complete `make validate` and `git diff --check` gates.

Live verification occurs only after the committed change is deployed. It verifies the active Google account, Connect Gateway credentials, `kubectl auth can-i '*' '*' --all-namespaces`, Grafana Deployment availability, a loopback-only port-forward, and Grafana's `/api/health` response. Verification records pass/fail metadata only and never captures the administrator password, kubeconfig, token, dashboard query results, or unredacted screenshots.

## Rollout

1. Implement and validate the repository changes without mutating GCP or Kubernetes.
2. Set the repository variable `GCP_CLUSTER_ADMIN_EMAIL` to the approved email.
3. Commit and push the implementation through the normal review path.
4. Run the manual Deploy workflow so Terraform IAM and both cluster bindings reconcile.
5. Authenticate locally as the approved user, run the helper, retrieve the Grafana password directly from Secret Manager, and open the loopback URL.
6. Record only redacted access-verification evidence.

The implementation does not automatically expose Grafana publicly or leave a background tunnel running.
