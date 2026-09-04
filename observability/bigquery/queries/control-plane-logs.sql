-- Standard GoogleSQL
-- Routed table: the normalized `container.googleapis.com/apiserver` log ID.
SELECT
  timestamp,
  severity,
  resource.labels.cluster_name AS cluster_name,
  resource.labels.location AS location,
  resource.labels.component_name AS component_name,
  jsonPayload.message AS message
FROM `${GCP_PROJECT_ID}.${BIGQUERY_DATASET}.container_googleapis_com_apiserver`
WHERE timestamp BETWEEN @start_time AND @end_time
  AND resource.type = 'k8s_control_plane_component'
  AND resource.labels.component_name = 'apiserver'
ORDER BY timestamp DESC
LIMIT 200;
