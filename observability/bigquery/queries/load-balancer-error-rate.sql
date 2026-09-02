-- Standard GoogleSQL
-- Likely routed table: the partitioned table for the `requests` log ID.
SELECT
  TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
  COUNT(*) AS request_count,
  COUNTIF(httpRequest.status BETWEEN 500 AND 599) AS error_count,
  100.0 * SAFE_DIVIDE(
    COUNTIF(httpRequest.status BETWEEN 500 AND 599),
    COUNT(*)
  ) AS error_rate_percent
FROM `${GCP_PROJECT_ID}.${BIGQUERY_DATASET}.requests`
WHERE timestamp BETWEEN @start_time AND @end_time
  AND resource.type = 'http_load_balancer'
GROUP BY time
ORDER BY time;
