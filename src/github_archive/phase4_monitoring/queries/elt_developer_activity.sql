-- ELT: Top developers from Dataform-style mart view

SELECT
    day,
    actor_login,
    total_events,
    pushes,
    issues_opened,
    prs_opened,
    comments,
    distinct_commits,
    repos_touched,
    active_minutes
FROM `PROJECT_ID.github_archive.developer_daily_activity`
ORDER BY total_events DESC
LIMIT 50
