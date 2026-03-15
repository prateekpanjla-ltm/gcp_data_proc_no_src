"""BigQuery schema definitions for GitHub Archive data."""

from typing import List

from google.cloud import bigquery


# Event types supported by GitHub Archive
SUPPORTED_EVENT_TYPES = [
    "PushEvent",
    "CreateEvent",
    "DeleteEvent",
    "WatchEvent",
    "IssuesEvent",
    "IssueCommentEvent",
    "PullRequestEvent",
    "PullRequestReviewEvent",
    "PullRequestReviewCommentEvent",
    "ForkEvent",
    "ReleaseEvent",
    "CommitCommentEvent",
    "MemberEvent",
    "PublicEvent",
    "GollumEvent",
    "TeamAddEvent",
    "DownloadEvent",
    "FollowEvent",
    "PageBuildEvent"
]


def get_github_events_schema() -> List[bigquery.SchemaField]:
    """Return the BigQuery schema for GitHub events table."""

    return [
        # Primary fields
        bigquery.SchemaField("event_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("event_type", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("created_at", "TIMESTAMP", mode="REQUIRED"),

        # Actor (user who performed the action)
        bigquery.SchemaField("actor_id", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("actor_login", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("actor_display_login", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("actor_gravatar_id", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("actor_url", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("actor_avatar_url", "STRING", mode="NULLABLE"),

        # Repository information
        bigquery.SchemaField("repo_id", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("repo_name", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("repo_url", "STRING", mode="NULLABLE"),

        # Organization (if applicable)
        bigquery.SchemaField("org_id", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("org_login", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("org_url", "STRING", mode="NULLABLE"),

        # Payload (full JSON for flexibility)
        bigquery.SchemaField("payload", "JSON", mode="NULLABLE"),

        # Common extracted payload fields (for query performance)
        bigquery.SchemaField("action", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("ref", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("ref_type", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("master_branch", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("description", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("pusher_type", "STRING", mode="NULLABLE"),

        # Push event specific
        bigquery.SchemaField("push_size", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("push_distinct_size", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("push_head", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("push_before", "STRING", mode="NULLABLE"),

        # Pull request specific
        bigquery.SchemaField("pr_number", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("pr_state", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("pr_title", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("pr_body", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("pr_merged", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("pr_merge_commit_sha", "STRING", mode="NULLABLE"),

        # Issue specific
        bigquery.SchemaField("issue_number", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("issue_state", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("issue_title", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("issue_body", "STRING", mode="NULLABLE"),

        # Release specific
        bigquery.SchemaField("release_tag_name", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("release_name", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("release_draft", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("release_prerelease", "BOOLEAN", mode="NULLABLE"),

        # Metadata
        bigquery.SchemaField("public", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("ingestion_timestamp", "TIMESTAMP", mode="REQUIRED"),
        bigquery.SchemaField("processed_at", "TIMESTAMP", mode="REQUIRED"),
    ]


def get_repositories_schema() -> List[bigquery.SchemaField]:
    """Return the BigQuery schema for repositories dimension table."""

    return [
        bigquery.SchemaField("repo_id", "INTEGER", mode="REQUIRED"),
        bigquery.SchemaField("repo_name", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("owner_id", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("owner_name", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("description", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("language", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("created_at", "TIMESTAMP", mode="NULLABLE"),
        bigquery.SchemaField("updated_at", "TIMESTAMP", mode="NULLABLE"),
        bigquery.SchemaField("pushed_at", "TIMESTAMP", mode="NULLABLE"),
        bigquery.SchemaField("size", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("stargazers_count", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("watchers_count", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("forks_count", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("open_issues_count", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("has_issues", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("has_wiki", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("has_pages", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("has_projects", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("is_fork", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("default_branch", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("license", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("topics", "STRING", mode="REPEATED"),
        bigquery.SchemaField("last_updated", "TIMESTAMP", mode="REQUIRED"),
    ]


def get_users_schema() -> List[bigquery.SchemaField]:
    """Return the BigQuery schema for users dimension table."""

    return [
        bigquery.SchemaField("user_id", "INTEGER", mode="REQUIRED"),
        bigquery.SchemaField("login", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("name", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("email", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("bio", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("location", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("blog", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("company", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("type", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("followers_count", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("following_count", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("public_repos_count", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("public_gists_count", "INTEGER", mode="NULLABLE"),
        bigquery.SchemaField("created_at", "TIMESTAMP", mode="NULLABLE"),
        bigquery.SchemaField("updated_at", "TIMESTAMP", mode="NULLABLE"),
        bigquery.SchemaField("site_admin", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("hireable", "BOOLEAN", mode="NULLABLE"),
        bigquery.SchemaField("twitter_username", "STRING", mode="NULLABLE"),
        bigquery.SchemaField("last_updated", "TIMESTAMP", mode="REQUIRED"),
    ]
