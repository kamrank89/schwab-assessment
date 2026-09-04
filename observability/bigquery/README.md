# BigQuery routed-log queries

This directory contains bounded Standard GoogleSQL examples for the partitioned
BigQuery dataset created by `infra/foundation/logging_bigquery.tf`. The SQL files
are templates, not records of live query results. BigQuery query validity, log
ingestion, Grafana rendering, and all other deployment evidence are pending.

## Routed table and schema behavior

Cloud Logging writes one BigQuery table per log name, not one table per
monitored-resource type. Because this sink sets `use_partitioned_tables = true`,
the table name is the normalized log ID without a date suffix, and rows are
partitioned by the log entry `timestamp`. For example, `kube-apiserver` normally
becomes `kube_apiserver`; characters unsupported by BigQuery identifiers are
replaced with underscores.

The templates use these likely table names:

| Log source | Likely partitioned table | Required source filter |
| --- | --- | --- |
| Application standard output | `stdout` | `resource.type = 'k8s_container'` plus the `assessment` namespace and application containers |
| Kubelet node logs | `kubelet` | `resource.type = 'k8s_node'` |
| Kubernetes API server | `kube_apiserver` | `resource.type = 'k8s_control_plane_component'` and `component_name = 'apiserver'` |
| External Application Load Balancer requests | `requests` | `resource.type = 'http_load_balancer'` |

These names are the exact contract consumed by the committed queries. Tables do not
exist until the first matching record arrives. Other routed log names create
other tables, such as `stderr`, `events`, `container_runtime`,
`node_problem_detector`, `kube_scheduler`, and `kube_controller_manager`.
Smoke runs `queries/schema-discovery.sql` after deployment and ingestion. If an
exact required table or compatible top-level column is absent, the bounded gate
times out before dry-running any query. Reconcile a deployment-specific mismatch
through a reviewed query/sink change; do not edit a template ad hoc inside the
protected run.

The first record routed to a new table determines its initial schema. Later
records can add fields within BigQuery limits, but a field-type change or a new
field that would exceed the column limit causes a schema mismatch. For this
partitioned sink, Logging writes mismatch details to `export_errors`. Inspect
that table when expected records are absent. Payload fields in particular can
differ between `textPayload` and `jsonPayload`; schema discovery must precede
live integration.

Google documents the behavior in [View logs routed to
BigQuery](https://cloud.google.com/logging/docs/export/bigquery) and the metadata
view in [COLUMNS view](https://cloud.google.com/bigquery/docs/information-schema-columns).

## Parameters and cost boundary

Replace `${GCP_PROJECT_ID}` and `${BIGQUERY_DATASET}` with the deployed project
and dataset IDs. Every data query requires named `TIMESTAMP` parameters:

- `@start_time`: inclusive beginning of the requested window.
- `@end_time`: inclusive end of the requested window.

Each data template uses `timestamp BETWEEN @start_time AND @end_time` so
BigQuery can prune the timestamp partitions. Raw-log templates also select only
useful columns and cap returned rows. `schema-discovery.sql` is the sole
timestamp-predicate exception because it reads
`INFORMATION_SCHEMA.COLUMNS` metadata rather than log data.

Grafana provisions the BigQuery datasource with `MaxBytesBilled: 1073741824`, a
1 GiB billed-byte ceiling per query. Queries above that limit fail instead of
running. Narrow the dashboard time range or aggregate further; do not remove the
cap as a troubleshooting shortcut.

## Protected dry-run workflow

Repository development does not run `bq`, `gcloud`, cloud authentication, or
deployment commands. After the protected workflow has authenticated with OIDC,
deployed the infrastructure and workloads, and received at least one record for
each source, it must:

1. Repeatedly execute rendered `schema-discovery.sql` as metadata-only Standard
   SQL until `stdout`, `requests`, `kubelet`, and `kube_apiserver` have the
   compatible top-level columns used by the committed queries.
2. Keep the returned schema payload out of reports and artifacts; record only
   the compatibility result.
3. Substitute the concrete project and dataset IDs.
4. Dry-run every query with Standard SQL and concrete time parameters before
   permitting any execution.

`scripts/verify.sh smoke` implements the readiness loop and the following
dry-run shape after the gate:

```bash
for query_file in observability/bigquery/queries/*.sql; do
  query_text="$(sed -e "s|\${GCP_PROJECT_ID}|${GCP_PROJECT_ID}|g" -e "s|\${BIGQUERY_DATASET}|${BIGQUERY_DATASET}|g" "${query_file}")"
  query_parameters=()
  if [[ "${query_file}" != */schema-discovery.sql ]]; then
    query_parameters+=(--parameter=start_time:TIMESTAMP:2026-09-01T00:00:00Z)
    query_parameters+=(--parameter=end_time:TIMESTAMP:2026-09-02T00:00:00Z)
  fi
  bq query --project_id="${GCP_PROJECT_ID}" --dry_run --use_legacy_sql=false "${query_parameters[@]}" "${query_text}"
done
```

Successful dry-runs prove parsing and compatibility with the deployed schema;
they do not prove returned data, datasource authentication, panel rendering, or
operational behavior. Those results remain deployment-evidence-pending until a
protected workflow records them.
