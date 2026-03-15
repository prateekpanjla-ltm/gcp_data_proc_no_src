# =============================================================================
# Outputs: Layer 03 Operational (Cloud Functions 2nd gen)
# =============================================================================

output "function_name" {
  description = "Cloud Function name"
  value       = google_cloudfunctions2_function.bq_loader.name
}

output "function_uri" {
  description = "Cloud Function URI"
  value       = google_cloudfunctions2_function.bq_loader.service_config[0].uri
}

output "function_state" {
  description = "Cloud Function state"
  value       = google_cloudfunctions2_function.bq_loader.state
}

output "source_bucket" {
  description = "Source bucket for function code"
  value       = google_storage_bucket.source.name
}
