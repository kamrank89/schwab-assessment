# Troubleshooting

Start from the first failed boundary and use read-only inspection before any mutation. Keep tokens, Terraform state, kubeconfigs, secret values, response bodies, and BigQuery rows out of tickets and artifacts.

## OIDC authentication denied

Check that the workflow ran from `refs/heads/main`, the repository/owner numeric IDs still match bootstrap, and all privileged jobs use the same provider, service account, and audience. Baseline jobs must not name a GitHub Environment. GitHub Environment jobs receive a different OIDC subject; follow the WIF-first migration in [GitHub setup](../setup/github.md).

Read-only checks:

```bash
gh run view <run-id> --log
git show main:.github/workflows/deploy.yml
git show main:infra/bootstrap/wif.tf
```

Do not solve authentication by adding a service-account JSON key or widening the provider to all branches/repositories.

## Terraform state or lock failure

Confirm `TF_STATE_BUCKET`, root prefix, default workspace, and whether another workflow owns the non-cancelling deployment concurrency group. Bootstrap state is `bootstrap/default.tfstate`; later roots use `foundation/default.tfstate` and `platform/default.tfstate`.

If bootstrap reports conflicting local/remote or `errored.tfstate`, stop. Do not delete state, force-copy an unreviewed snapshot, or bypass the script. Capture filenames and error classes only, then perform a controlled HashiCorp state recovery with an independent review.

Guarded teardown has two foundation-only proofs. A genuinely never-created platform requires a live foundation state and complete absence of live, noncurrent, and soft-deleted platform-state, controller-inventory, and completion-marker generations, plus absent supported clusters/local inventory. A partial foundation redeploy after successful teardown instead requires the exact valid empty platform generation/content to match the live completion marker, both clusters and live inventories to remain absent, and every recoverable inventory generation to be in that marker's bound set. The current foundation state is still read and destroyed independently.

Exact-object discovery runs separate exhaustive soft-delete listing. Any listing/access/API/malformed response, duplicate or transitioning identity, historical-only state, unknown inventory generation, absent/historical/malformed marker, or marker/platform mismatch stops rather than becoming absence. A normal full redeploy changes platform state, so its old marker is intentionally stale and strict MCI inventory cleanup is required. Recover the exact live state, inventory, or marker; never delete recoverable versions to manufacture a shortcut.

## Cluster or Fleet access failure

The clusters have private nodes, disabled IP endpoints, and an IAM-authorized DNS endpoint. Deployment first uses `gcloud container clusters get-credentials --dns-endpoint` to install narrow RBAC, then Fleet Connect Gateway for routine operations. Check `USE_GKE_GCLOUD_AUTH_PLUGIN=True`, the 582.0.0 CLI and plugin, IAM `container.clusters.connect`/Fleet permissions, membership readiness, and Kubernetes RBAC.

```bash
# LIVE READ ACCESS.
gcloud container clusters describe gke-assessment-us-central1 \
  --region=us-central1 --project="${GCP_PROJECT_ID}" --format='value(status)'
gcloud container fleet memberships describe gke-assessment-us-central1 \
  --location=global --project="${GCP_PROJECT_ID}" --format='value(state.code)'
```

## MCI has no VIP or unhealthy backends

Inspect the config membership, both MCS selectors, Pod readiness, Service ports, health paths (`/healthz` for App A and `/health` for App B), BackendConfig annotations, and controller events. MCI reconciliation can take time but every wait is bounded.

```bash
# LIVE READ ACCESS.
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment \
  describe multiclusteringress.networking.gke.io/assessment-ingress
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment \
  get multiclusterservices.networking.gke.io,pods,services
```

Do not manually delete controller-created load-balancer resources while MCI still owns them. Teardown inventories those exact resources first.

## DNS, certificate, or redirect failure

- `NXDOMAIN`: confirm the correct authoritative zone and registrar delegation.
- Wrong address: the A record must equal Terraform's reserved global IPv4.
- Certificate `PROVISIONING`: confirm the exact hostname publicly resolves to the load balancer, no conflicting records exist, and sufficient time has elapsed.
- HTTP stays 2xx after certificate activation: confirm the `https` overlay and `FrontendConfig` reconciled.
- HTTPS 4xx/5xx: separate frontend certificate status from backend health and application paths.
- HTTPS-to-HTTP preparation fails: keep foundation unchanged, confirm all three target booleans are false, both state outputs name the same certificate, the HTTP overlay removed both MCI annotations, and no target HTTPS/SSL proxy still references that certificate. Retry the guarded first dispatch; do not start the ordinary deletion dispatch until it succeeds.

Read-only checks:

```bash
dig +short app.example.com A
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' http://app.example.com/app-a
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' https://app.example.com/app-a
```

Never point an assessment certificate at a domain you do not own.

## Secret mount failure

Check Workload Identity annotations, namespace/service-account names, SecretProviderClass project number, CSI provider enablement, whether an enabled version exists, and secret-specific accessor IAM. Do not print or `cat` the mounted value into logs.

```bash
# LIVE READ ACCESS; metadata only.
KUBECONFIG="${ASSESSMENT_KUBECONFIG}" kubectl -n assessment describe pod <app-a-pod>
gcloud secrets versions list app-a-demo --project="${GCP_PROJECT_ID}" --format='table(name,state)'
```

## BigQuery has no tables or Grafana has no data

Log Router table creation is eventual and requires matching logs. Verify the sink writer has dataset editor and generate only benign assessment traffic. Smoke repeatedly executes the rendered metadata-only `schema-discovery.sql` until exact tables `stdout`, `requests`, `kubelet`, and `kube_apiserver` expose the required compatible top-level columns; it times out before any dry run if that contract is not met. The committed data queries require `start_time` and `end_time`; keep the window narrow. A successful dry run does not prove rows exist, and schema payloads/log rows must not enter workflow artifacts.

For Grafana, verify the Pod is Ready, the BigQuery plugin installed, and the exact ConfigMap named by the current Deployment's `dashboards` volume contains only the three expected JSON keys. Old hash-suffixed generator ConfigMaps can remain after apply and must not be counted. Also check that the Grafana runtime identity has BigQuery viewer/job-user and Monitoring viewer. Grafana uses ephemeral storage and may restart with no saved UI changes; committed provisioning is authoritative.

## Planned readiness-probe exercise — not yet executed

This is a future controlled troubleshooting demonstration, not a historical incident.

- **Injected condition:** under an approved test change, set one application's readiness path to a known invalid path in one region while leaving liveness unchanged.
- **Expected symptom:** because the Deployment uses `maxUnavailable: 0` and `maxSurge: 1`, the three old Pods remain healthy and Ready while one surge Pod with the bad probe stays unready. The rollout stalls at three healthy old Pods plus one unready new Pod; it does not produce `0/3 Ready`.
- **Traffic effect:** the existing regional Service endpoints and MCI backend remain healthy through the old Pods, so this normal rolling-update failure is not expected to trigger regional backend failover. A different concurrent failure could change that outcome and must be recorded separately rather than assumed.
- **Diagnosis:** compare the new ReplicaSet's probe configuration with the image health contract; inspect Deployment/ReplicaSet conditions, `kubectl describe pod`, events, readiness failures, rollout status, endpoint slices, and MCI backend health. Confirm that the old ReplicaSet still supplies the three Ready endpoints. Do not start by deleting Pods.
- **Correction:** revert the probe path to `/healthz` for App A or `/health` for App B in source, pass account-free validation, merge through review, and redeploy.
- **Expected recovery:** a corrected surge Pod becomes Ready, allowing the controller to replace old Pods one at a time while preserving availability. The rollout completes; a subsequent `verify.sh smoke` or deploy-workflow smoke record must prove the exact three desired/Ready/updated/available replicas and healthy global routes. Backend recovery is not claimed because the normal scenario did not make the backend unhealthy.
- **Prevention:** document image health endpoints, exercise them in pre-production, review probe changes through CODEOWNERS, use bounded rollout gates, and retain the healthy cross-region backend during changes.

When authorized and executed, record actual UTC times, commit, workflow, commands, redacted outputs, the retained old-Pod availability, correction, recovery smoke, and reviewer. Until then its evidence status is `deployment-evidence-pending`.
