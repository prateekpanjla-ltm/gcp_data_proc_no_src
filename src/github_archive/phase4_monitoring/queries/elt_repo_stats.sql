-- ELT: Top repositories from materialized view (auto-refreshed)

SELECT
    day,
    repo_name,
    total_events,
    pushes,
    issues,
    pull_requests,
    stars,
    forks,
    unique_contributors
FROM `PROJECT_ID.github_archive.mv_repo_daily_stats`
ORDER BY total_events DESC
LIMIT 50
