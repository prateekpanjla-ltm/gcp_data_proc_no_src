# =============================================================================
# ELT: Materialized View — Top Repositories (auto-refreshed by BQ)
# =============================================================================
resource "google_bigquery_table" "mv_repo_daily_stats" {
  dataset_id          = google_bigquery_dataset.github_archive.dataset_id
  table_id            = "mv_repo_daily_stats"
  deletion_protection = false
  description         = "Materialized view: daily repo activity stats (auto-refreshed)"

  materialized_view {
    query               = <<-SQL
      SELECT
        DATE(created_at) AS day,
        repo_name,
        COUNT(*) AS total_events,
        COUNTIF(event_type = 'PushEvent') AS pushes,
        COUNTIF(event_type = 'IssuesEvent') AS issues,
        COUNTIF(event_type = 'PullRequestEvent') AS pull_requests,
        COUNTIF(event_type = 'WatchEvent') AS stars,
        COUNTIF(event_type = 'ForkEvent') AS forks,
        APPROX_COUNT_DISTINCT(actor_login) AS unique_contributors
      FROM `${var.project_id}.${var.dataset_id}.${var.table_id}`
      GROUP BY day, repo_name
    SQL
    enable_refresh      = true
    refresh_interval_ms = 1800000 # 30 minutes
  }

  depends_on = [google_bigquery_table.github_events]

  labels = merge(local.common_labels, { elt_type = "materialized_view" })
}

# =============================================================================
# ELT: Scheduled Query — Hourly Activity Summary
# =============================================================================
resource "google_bigquery_data_transfer_config" "hourly_activity" {
  display_name   = "${var.environment}-hourly-activity-summary"
  location       = var.region
  data_source_id = "scheduled_query"

  schedule = "every 1 hours"

  destination_dataset_id = google_bigquery_dataset.github_archive.dataset_id

  params = {
    destination_table_name_template = "hourly_activity_summary"
    write_disposition               = "WRITE_APPEND"
    query = replace(
      replace(
        replace(
          file("${path.module}/sql/scheduled_hourly_activity.sql"),
          "PROJECT_ID", var.project_id
        ),
        "DATASET_ID", var.dataset_id
      ),
      "TABLE_ID", var.table_id
    )
  }

  service_account_name = google_service_account.bq_loader.email

  depends_on = [
    google_bigquery_table.github_events,
    google_project_service.bigquery,
    google_project_service.bigquery_datatransfer,
    google_project_iam_member.bq_loader_data_transfer,
  ]
}

# IAM: bq_loader SA needs permissions to run scheduled queries via Data Transfer
resource "google_project_iam_member" "bq_loader_data_transfer" {
  project = var.project_id
  role    = "roles/bigquery.admin"
  member  = "serviceAccount:${google_service_account.bq_loader.email}"
}

# =============================================================================
# ELT: Dataform — Developer Activity Analysis
# =============================================================================
# Dataform requires a repository and compilation result.
# For simplicity, we define the SQL transformations as BQ views here
# and note that a full Dataform project would use .sqlx files with
# ${ref()} dependencies.

# Staging view: deduplicated events (simulates Dataform staging layer)
resource "google_bigquery_table" "view_stg_events" {
  dataset_id          = google_bigquery_dataset.github_archive.dataset_id
  table_id            = "stg_events"
  deletion_protection = false
  description         = "Staging view: deduplicated events (Dataform-style staging layer)"

  view {
    query          = <<-SQL
      SELECT
        event_id,
        event_type,
        created_at,
        actor_login,
        actor_id,
        repo_name,
        repo_id,
        payload_ref,
        payload_size,
        payload_distinct_size,
        payload_issue_labels,
        etl_create_ts
      FROM `${var.project_id}.${var.dataset_id}.${var.table_id}`
      WHERE event_id IS NOT NULL
      QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY etl_create_ts DESC) = 1
    SQL
    use_legacy_sql = false
  }

  depends_on = [google_bigquery_table.github_events]

  labels = merge(local.common_labels, { elt_type = "dataform_staging" })
}

# Mart view: developer daily activity (simulates Dataform mart layer)
resource "google_bigquery_table" "view_developer_activity" {
  dataset_id          = google_bigquery_dataset.github_archive.dataset_id
  table_id            = "developer_daily_activity"
  deletion_protection = false
  description         = "Mart view: per-developer daily stats (Dataform-style mart layer)"

  view {
    query          = <<-SQL
      SELECT
        DATE(created_at) AS day,
        actor_login,
        actor_id,
        COUNT(*) AS total_events,
        COUNTIF(event_type = 'PushEvent') AS pushes,
        COUNTIF(event_type = 'IssuesEvent') AS issues_opened,
        COUNTIF(event_type = 'PullRequestEvent') AS prs_opened,
        COUNTIF(event_type = 'IssueCommentEvent') AS comments,
        SUM(IFNULL(payload_distinct_size, 0)) AS distinct_commits,
        COUNT(DISTINCT repo_name) AS repos_touched,
        MIN(created_at) AS first_event,
        MAX(created_at) AS last_event,
        TIMESTAMP_DIFF(MAX(created_at), MIN(created_at), MINUTE) AS active_minutes
      FROM `${var.project_id}.${var.dataset_id}.stg_events`
      GROUP BY day, actor_login, actor_id
    SQL
    use_legacy_sql = false
  }

  depends_on = [google_bigquery_table.view_stg_events]

  labels = merge(local.common_labels, { elt_type = "dataform_mart" })
}

# Mart view: bot vs human activity (simulates Dataform mart layer)
resource "google_bigquery_table" "view_bot_vs_human" {
  dataset_id          = google_bigquery_dataset.github_archive.dataset_id
  table_id            = "bot_vs_human_activity"
  deletion_protection = false
  description         = "Mart view: bot vs human daily activity breakdown (Dataform-style mart layer)"

  view {
    query          = <<-SQL
      SELECT
        DATE(created_at) AS day,
        CASE
          WHEN actor_login LIKE '%[bot]' THEN 'bot'
          WHEN actor_login LIKE '%-bot' THEN 'bot'
          WHEN actor_login LIKE '%Bot' THEN 'bot'
          WHEN actor_login IN ('dependabot', 'renovate', 'github-actions') THEN 'bot'
          ELSE 'human'
        END AS actor_type,
        COUNT(*) AS event_count,
        COUNT(DISTINCT actor_login) AS unique_actors,
        COUNT(DISTINCT repo_name) AS unique_repos,
        COUNTIF(event_type = 'PushEvent') AS pushes,
        COUNTIF(event_type = 'PullRequestEvent') AS prs
      FROM `${var.project_id}.${var.dataset_id}.stg_events`
      GROUP BY day, actor_type
    SQL
    use_legacy_sql = false
  }

  depends_on = [google_bigquery_table.view_stg_events]

  labels = merge(local.common_labels, { elt_type = "dataform_mart" })
}
