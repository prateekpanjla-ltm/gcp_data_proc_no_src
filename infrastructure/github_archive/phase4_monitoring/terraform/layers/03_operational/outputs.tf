output "dashboard_url" {
  value = google_cloud_run_v2_service.dashboard.uri
}

output "log_sink_name" {
  value = google_logging_project_sink.pipeline_logs.name
}
