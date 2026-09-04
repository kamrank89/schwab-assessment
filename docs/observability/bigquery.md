# BigQuery log analysis

Terraform creates `assessment_logs` in the `US` multi-region with partition expiration of 30 days. A project Log Router sink with a unique writer identity routes GKE container/node/control-plane/cluster and HTTP load-balancer logs into partitioned BigQuery tables. The sink writer receives dataset editor; Grafana receives dataset viewer plus project job user.

## Query inventory

| File | Intent |
| --- | --- |
| `schema-discovery.sql` | Discover routed table schemas through `INFORMATION_SCHEMA.COLUMNS` |
| `application-logs.sql` | Recent App A/App B container logs |
| `control-plane-logs.sql` | API server log sample |
| `node-logs.sql` | Kubelet/node log sample |
| `load-balancer-logs.sql` | Recent request metadata |
| `load-balancer-error-rate.sql` | Per-minute 5xx rate |
| `traffic-analysis.sql` | Status counts and p50/p95/p99 latency |

Cloud Logging normalizes log IDs into table names, and tables appear only after matching log entries are routed. Smoke requires exact tables `stdout`, `requests`, `kubelet`, and `container_googleapis_com_apiserver`. Its bounded readiness loop executes the rendered metadata-only schema discovery query until those tables expose the top-level fields used by the committed SQL: `timestamp` (`TIMESTAMP`); `severity`/`textPayload` (`STRING`) where referenced; and `resource`, `httpRequest`, or `jsonPayload` (`STRUCT`) where referenced. A different name or incompatible type is a deployment-specific incompatibility and times out before dry runs; repository development does not claim the live schema.

## Bounded execution

Smoke verification replaces only `${GCP_PROJECT_ID}` and `${BIGQUERY_DATASET}`. It captures schema-discovery rows in memory for compatibility evaluation and never writes them or log rows to the report/artifact. After compatibility succeeds, six data queries receive UTC `start_time` and `end_time` parameters; schema discovery receives none. Only then does every query get a `bq query --dry_run --use_legacy_sql=false` before it can be cited as valid in that deployment.

A direct dry run follows the same form used by the retained smoke runs:

```bash
# LIVE QUERY METADATA/API usage; dry run estimates bytes but returns no data rows.
bq query --project_id="${GCP_PROJECT_ID}" \
  --dry_run --use_legacy_sql=false \
  --parameter=start_time:TIMESTAMP:"2026-09-02T12:00:00Z" \
  --parameter=end_time:TIMESTAMP:"2026-09-02T13:00:00Z" \
  "$(sed -e "s|\${GCP_PROJECT_ID}|${GCP_PROJECT_ID}|g" \
           -e "s|\${BIGQUERY_DATASET}|assessment_logs|g" \
           observability/bigquery/queries/traffic-analysis.sql)"
```

For actual evidence, keep the partition/time window small, select only necessary columns, review estimated bytes first, and redact query rows. `LIMIT` does not itself cap bytes processed. Grafana separately caps bytes billed to 1 GiB per query.

## Evidence boundary

Committed SQL and static Terraform prove intended filters and sink configuration. A dry run proves syntax/type resolution against the live schema and estimates processing. Neither proves relevant rows, completeness, retention, permissions, or dashboard results. Record those only through the live evidence template.

Current Google guidance notes that on-demand queries bill by bytes processed and partition pruning reduces scanned data; see [BigQuery pricing](https://cloud.google.com/bigquery/pricing) and [cost controls](https://cloud.google.com/bigquery/docs/best-practices-costs).
