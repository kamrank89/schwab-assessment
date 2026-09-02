# Grafana

Grafana runs as one recoverable supporting Pod in `us-central1`. It is internal-only (`ClusterIP`) and accessed through a controlled Connect Gateway port-forward. `emptyDir` stores plugins, data, and logs, so a restart rebuilds from committed provisioning; no assessment claim depends on UI-persisted state.

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

`make validate-grafana` proves all committed JSON parses. `verify.sh smoke` proves only in a future live run that the Grafana Deployment is Ready and exactly three exports are provisioned. Datasource success and populated panels require live data and remain pending.

## Safe access and evidence

Follow [verification](../operations/verification.md) for a fresh kubeconfig and port-forward. Retrieve the password through an approved secret-access path without printing it. Prefer the committed JSON exports as the assessment artifact. If a screenshot is required, show the four overview panels and UTC window while redacting project/user/browser/session information and any log content with IPs or payloads.

## Recovery

If Grafana is lost, redeploy the primary overlay; do not attempt to recover `emptyDir`. Validate the password mount, plugin install, datasources, dashboard ConfigMaps, Deployment readiness, and a narrow query window. Production should add durable state where required, high availability, SSO, network access controls, plugin provenance management, alerting, and backup/restore.
