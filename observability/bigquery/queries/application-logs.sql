-- Standard GoogleSQL
-- Likely routed table: the partitioned table for application `stdout` logs.
SELECT
  timestamp,
  severity,
  resource.labels.cluster_name AS cluster_name,
  resource.labels.location AS location,
  resource.labels.namespace_name AS namespace_name,
  resource.labels.pod_name AS pod_name,
  resource.labels.container_name AS container_name,
  textPayload AS message
FROM `${GCP_PROJECT_ID}.${BIGQUERY_DATASET}.stdout`
WHERE timestamp BETWEEN @start_time AND @end_time
  AND resource.type = 'k8s_container'
  AND resource.labels.namespace_name = 'assessment'
  AND resource.labels.container_name IN ('app-a', 'app-b')
ORDER BY timestamp DESC
LIMIT 200;
