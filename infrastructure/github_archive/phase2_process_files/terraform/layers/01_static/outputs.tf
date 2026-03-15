# Layer 01: Static Outputs
# These outputs are used by Layer 03 (Operational)

output "project_id" {
  description = "Google Cloud Project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP Region"
  value       = var.region
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

output "staging_bucket_name" {
  description = "Name of the staging bucket"
  value       = google_storage_bucket.staging.name
}

output "processor_service_account_email" {
  description = "Email of the processor service account"
  value       = google_service_account.processor.email
}

output "splitter_service_account_email" {
  description = "Email of the file splitter service account"
  value       = google_service_account.splitter.email
}

output "eventarc_invoker_service_account_email" {
  description = "Email of the Eventarc invoker service account"
  value       = google_service_account.eventarc_invoker.email
}

output "processor_service_account_name" {
  description = "Name (not email) of the processor service account"
  value       = google_service_account.processor.name
}

output "landing_bucket_name" {
  description = "Name of the landing bucket"
  value       = var.landing_bucket_name
}
