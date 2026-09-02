-- Standard GoogleSQL
-- Likely routed table: the partitioned table for `kubelet` node logs.
SELECT
  timestamp,
  severity,
  resource.labels.cluster_name AS cluster_name,
  resource.labels.location AS location,
  resource.labels.node_name AS node_name,
  jsonPayload.message AS message
FROM `${GCP_PROJECT_ID}.${BIGQUERY_DATASET}.kubelet`
WHERE timestamp BETWEEN @start_time AND @end_time
  AND resource.type = 'k8s_node'
ORDER BY timestamp DESC
LIMIT 200;
