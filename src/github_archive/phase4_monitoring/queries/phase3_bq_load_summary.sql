-- Phase 3 BQ load summary: load jobs + row counts per day
-- Combines INFORMATION_SCHEMA.JOBS for job metadata with github_events row counts

SELECT
    DATE(j.creation_time, 'Asia/Kolkata') AS load_date,
    j.job_type,
    j.job_id,
    CASE j.state
        WHEN 'DONE' THEN IF(j.error_result IS NULL, 'success', 'failed')
        ELSE j.state
    END AS status,
    r.rows_loaded,
    DATETIME(j.creation_time, 'Asia/Kolkata') AS timestamp_ist
FROM `region-us-central1`.INFORMATION_SCHEMA.JOBS j
LEFT JOIN (
    SELECT DATE(created_at) AS event_date, COUNT(*) AS rows_loaded
    FROM `PROJECT_ID.github_archive.github_events`
    GROUP BY event_date
) r ON r.event_date = DATE(j.creation_time)
WHERE
    j.job_type = 'LOAD'
    AND j.destination_table.table_id = 'github_events'
ORDER BY j.creation_time DESC
LIMIT 50
