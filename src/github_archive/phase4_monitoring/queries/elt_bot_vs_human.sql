-- ELT: Bot vs human activity from Dataform-style mart view

SELECT
    day,
    actor_type,
    event_count,
    unique_actors,
    unique_repos,
    pushes,
    prs
FROM `PROJECT_ID.github_archive.bot_vs_human_activity`
ORDER BY day DESC, event_count DESC
