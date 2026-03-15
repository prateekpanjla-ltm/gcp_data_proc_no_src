# Phase 4 Monitoring — Static Resources
# BQ dataset for log exports, service account for dashboard

resource "google_bigquery_dataset" "pipeline_logs" {
  dataset_id = "${var.environment}_pipeline_logs"
  project    = var.project_id
  location   = var.region

  description = "Cloud Logging exports for GitHub Archive pipeline monitoring (${var.environment})"

  # Logs are transient — 90 day retention
  default_table_expiration_ms = 7776000000 # 90 days

  # Allow terraform destroy to delete dataset even when tables exist
  delete_contents_on_destroy = true
}

# Dashboard SA — used by the Cloud Run dashboard service to query BQ.
# NOT used for the log sink (GCP forces an auto-generated writer identity there).
resource "google_service_account" "dashboard" {
  account_id   = "${var.environment}-pipeline-dashboard"
  display_name = "${title(var.environment)} Pipeline Dashboard"
  project      = var.project_id
}
