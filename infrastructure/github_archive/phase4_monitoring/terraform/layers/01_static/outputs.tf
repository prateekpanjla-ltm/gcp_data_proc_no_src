output "pipeline_logs_dataset_id" {
  value = google_bigquery_dataset.pipeline_logs.dataset_id
}

output "dashboard_sa_email" {
  value = google_service_account.dashboard.email
}
