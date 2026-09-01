-- Standard GoogleSQL
-- Metadata exception: this query reads INFORMATION_SCHEMA.COLUMNS, not log
-- data, so it intentionally has no timestamp predicate or time parameters.
SELECT
  table_name,
  ordinal_position,
  column_name,
  data_type,
  is_nullable
FROM `${GCP_PROJECT_ID}.${BIGQUERY_DATASET}.INFORMATION_SCHEMA.COLUMNS`
ORDER BY table_name, ordinal_position;
