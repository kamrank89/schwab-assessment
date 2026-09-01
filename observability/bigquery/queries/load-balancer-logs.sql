-- Standard GoogleSQL
-- Likely routed table: the partitioned table for the `requests` log ID.
SELECT
  timestamp,
  httpRequest.status AS status,
  httpRequest.requestMethod AS method,
  httpRequest.requestUrl AS url,
  httpRequest.remoteIp AS remote_ip,
  httpRequest.latency AS latency,
  resource.labels.backend_service_name AS backend_service_name,
  resource.labels.url_map_name AS url_map_name
FROM `${GCP_PROJECT_ID}.${BIGQUERY_DATASET}.requests`
WHERE timestamp BETWEEN @start_time AND @end_time
  AND resource.type = 'http_load_balancer'
ORDER BY timestamp DESC
LIMIT 200;
