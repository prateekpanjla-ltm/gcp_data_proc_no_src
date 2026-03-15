# =============================================================================
# Outputs: Layer 01 Static
# =============================================================================

output "dataset_id" {
  description = "BigQuery dataset ID"
  value       = google_bigquery_dataset.github_archive.dataset_id
}

output "dataset_name" {
  description = "BigQuery dataset friendly name"
  value       = google_bigquery_dataset.github_archive.friendly_name
}
output "table_id" {
  description = "BigQuery table ID"
  value       = google_bigquery_table.github_events.table_id
}
output "service_account_email_bq_loader" {
  description = "BigQuery loader service account email"
  value       = google_service_account.bq_loader.email
}
output "service_account_email_eventarc_invoker" {
  description = "Eventarc invoker service account email"
  value       = google_service_account.eventarc_invoker.email
}
