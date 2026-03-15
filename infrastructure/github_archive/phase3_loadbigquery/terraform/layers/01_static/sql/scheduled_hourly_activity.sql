-- Scheduled Query: Hourly Activity Summary
-- Runs every hour, appends aggregated stats to destination table
-- Summarizes event counts, unique actors/repos per event type per hour

SELECT
  TIMESTAMP_TRUNC(created_at, HOUR) AS hour,
  event_type,
  COUNT(*) AS event_count,
  COUNT(DISTINCT actor_login) AS unique_actors,
  COUNT(DISTINCT repo_name) AS unique_repos,
  SUM(IFNULL(payload_size, 0)) AS total_commits,
  SUM(IFNULL(payload_distinct_size, 0)) AS distinct_commits,
  CURRENT_TIMESTAMP() AS etl_processed_at
FROM `PROJECT_ID.DATASET_ID.TABLE_ID`
WHERE created_at >= TIMESTAMP_SUB(@run_time, INTERVAL 2 HOUR)
  AND created_at < TIMESTAMP_TRUNC(@run_time, HOUR)
GROUP BY hour, event_type
