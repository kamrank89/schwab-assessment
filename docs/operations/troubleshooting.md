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

Log Router table creation is eventual and requires matching logs. Verify the sink writer has dataset editor, generate only benign assessment traffic, wait for the bounded smoke loop, and use `schema-discovery.sql` to inspect table names. The committed data queries require `start_time` and `end_time`; keep the window narrow. A successful dry run does not prove rows exist.

For Grafana, verify the Pod is Ready, the BigQuery plugin installed, three dashboard ConfigMaps are present, and the Grafana runtime identity has BigQuery viewer/job-user and Monitoring viewer. Grafana uses ephemeral storage and may restart with no saved UI changes; committed provisioning is authoritative.

## Planned readiness-probe exercise — not yet executed

This is a future controlled troubleshooting demonstration, not a historical incident.

- **Injected condition:** under an approved test change, set one application's readiness path to a known invalid path in one region while leaving liveness unchanged.
- **Expected symptom:** the new Pods run but remain `0/3 Ready`; rollout times out; the affected MCI backend becomes unhealthy and global traffic should use the other healthy region.
- **Diagnosis:** compare Deployment probe configuration with the image health contract, inspect `kubectl describe pod`, events, readiness failures, rollout status, and MCI backend health. Do not start by deleting Pods.
- **Correction:** revert the probe path to `/healthz` for App A or `/health` for App B in source, pass account-free validation, merge through review, and redeploy.
- **Expected recovery:** three Ready replicas return in the affected region, rollout succeeds, all MCI backends become healthy, and both global routes return the expected status class.
- **Prevention:** document image health endpoints, exercise them in pre-production, review probe changes through CODEOWNERS, use bounded rollout gates, and retain the healthy cross-region backend during changes.

When authorized and executed, record actual UTC times, commit, workflow, commands, redacted outputs, correction, recovery, and reviewer. Until then its evidence status is `deployment-evidence-pending`.
