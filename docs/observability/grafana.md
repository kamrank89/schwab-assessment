# Grafana

Grafana runs as one recoverable supporting Pod in `us-central1` and is internal-only (`ClusterIP`). The committed baseline provisions no interactive human Connect Gateway/RBAC access path. `emptyDir` stores plugins, data, and logs, so a restart rebuilds from committed provisioning; no assessment claim depends on UI-persisted state.

## Provisioned datasources

- `gcp-monitoring` uses the Google Cloud datasource with the Grafana workload identity.
- `gcp-bigquery` uses plugin version 3.4.0, is restricted to the configured `assessment_logs` dataset in `US`, and caps `MaxBytesBilled` at 1 GiB per query.

The runtime GSA has Monitoring viewer, BigQuery job user, and dataset data viewer. The admin password is mounted from Secret Manager; anonymous access and user signup are disabled, reporting/update checks are disabled, and dashboards are non-editable/deletion-protected through file provisioning.

## Committed dashboard exports

| Export | Purpose |
| --- | --- |
| `assessment-overview.json` | Required application error rate, Pod restarts, p50/p95/p99 request latency, CPU and memory utilization |
| `multicluster-operations.json` | Serving-region request volume, restarts by cluster, global backend p95 latency |
| `traffic-log-analysis.json` | HTTP status traffic, top request paths, recent 5xx logs |

`make validate-grafana` proves all committed JSON parses. `verify.sh smoke` proves only in a future live run that the Grafana Deployment is Ready and the exact ConfigMap referenced by its current `dashboards` volume has exactly these three JSON keys. Stale hash-suffixed ConfigMaps left by plain apply are ignored. Datasource success and populated panels require live data and remain pending.

## Access and evidence boundary

Follow [verification](../operations/verification.md) for the exact boundary. Automated smoke checks only Pod readiness and committed provisioning; it does not log into the UI or prove datasource results. The committed JSON exports are the baseline assessment artifact. A live screenshot requires a separately approved temporary human identity, Connect Gateway IAM, Kubernetes RBAC, Secret Manager access, expiry, audit record, and redaction plan outside this baseline. If such access is later approved, redact project/user/browser/session information and any log content with IPs or payloads.

## Recovery

If Grafana is lost, redeploy the primary overlay; do not attempt to recover `emptyDir`. Validate the password mount, plugin install, datasources, the dashboard ConfigMap referenced by the current Deployment, Deployment readiness, and a narrow query window. Production should add durable state where required, high availability, SSO, network access controls, plugin provenance management, alerting, and backup/restore.
