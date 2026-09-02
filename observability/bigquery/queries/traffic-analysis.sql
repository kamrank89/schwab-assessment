-- Standard GoogleSQL
-- Load-balancer latency is a duration string such as `0.125s`; malformed values
-- become NULL instead of failing the query.
WITH request_logs AS (
  SELECT
    SAFE_CAST(httpRequest.status AS INT64) AS status,
    1000.0 * SAFE_CAST(
      REGEXP_EXTRACT(
        CAST(httpRequest.latency AS STRING),
        r'^([0-9]+(?:\.[0-9]+)?)s$'
      ) AS FLOAT64
    ) AS latency_ms
  FROM `${GCP_PROJECT_ID}.${BIGQUERY_DATASET}.requests`
  WHERE timestamp BETWEEN @start_time AND @end_time
    AND resource.type = 'http_load_balancer'
)
SELECT
  status,
  COUNT(*) AS request_count,
  ROUND(AVG(latency_ms), 2) AS average_latency_ms,
  ROUND(
    APPROX_QUANTILES(latency_ms, 100 IGNORE NULLS)[SAFE_OFFSET(50)],
    2
  ) AS p50_latency_ms,
  ROUND(
    APPROX_QUANTILES(latency_ms, 100 IGNORE NULLS)[SAFE_OFFSET(95)],
    2
  ) AS p95_latency_ms,
  ROUND(
    APPROX_QUANTILES(latency_ms, 100 IGNORE NULLS)[SAFE_OFFSET(99)],
    2
  ) AS p99_latency_ms
FROM request_logs
GROUP BY status
ORDER BY status;
