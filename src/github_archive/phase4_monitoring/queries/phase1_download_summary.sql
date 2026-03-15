-- Phase 1 download summary: files downloaded, size, timestamp
-- Parses download logs from Cloud Run Job stdout:
--   "Download completed: gs://bucket/path/filename (bytes bytes)"

SELECT
    DATE(timestamp, 'Asia/Kolkata') AS download_date,
    REGEXP_EXTRACT(textPayload, r'/([^/]+)\s*\(') AS file_name,
    CAST(REGEXP_EXTRACT(textPayload, r'\((\d+) bytes\)') AS INT64) AS file_size_bytes,
    ROUND(CAST(REGEXP_EXTRACT(textPayload, r'\((\d+) bytes\)') AS INT64) / 1048576.0, 1) AS file_size_mb,
    DATETIME(timestamp, 'Asia/Kolkata') AS timestamp_ist
FROM `PROJECT_ID.DATASET_ID.run_googleapis_com_stdout`
WHERE textPayload LIKE '%Download completed%'
ORDER BY timestamp DESC
LIMIT 50
