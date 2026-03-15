-- Daily pipeline throughput: files processed, total records, error rate
-- Aggregated view across Phase 2

SELECT
    DATE(timestamp, 'Asia/Kolkata') AS day,
    COUNT(*) AS files_processed,
    SUM(CAST(REGEXP_EXTRACT(textPayload, r'(\d+) in,') AS INT64)) AS total_records_in,
    SUM(CAST(REGEXP_EXTRACT(textPayload, r'(\d+) out,') AS INT64)) AS total_records_out,
    SUM(CAST(REGEXP_EXTRACT(textPayload, r'(\d+) errors,') AS INT64)) AS total_errors,
    ROUND(AVG(CAST(REGEXP_EXTRACT(textPayload, r'([\d.]+)s$') AS FLOAT64)), 1) AS avg_duration_s,
    ROUND(
        SAFE_DIVIDE(
            SUM(CAST(REGEXP_EXTRACT(textPayload, r'(\d+) errors,') AS INT64)),
            SUM(CAST(REGEXP_EXTRACT(textPayload, r'(\d+) in,') AS INT64))
        ) * 100, 2
    ) AS error_rate_pct
FROM `PROJECT_ID.DATASET_ID.run_googleapis_com_stderr`
WHERE
    textPayload LIKE '%Completed%'
    AND textPayload LIKE '%in,%out,%errors%'
GROUP BY day
ORDER BY day DESC
