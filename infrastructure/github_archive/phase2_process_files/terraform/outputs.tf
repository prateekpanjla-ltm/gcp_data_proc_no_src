# Phase 2: Process Files - Terraform Outputs

output "processor_service_url" {
  description = "URL of the processor Cloud Run Service"
  value = google_cloud_run_v2_service.processor.uri
}

output "storage_trigger_name" {
  description = "Name of the storage Eventarc trigger"
  value = google_eventarc_trigger.main_file_processor.name
}

output "staging_bucket_name" {
  description = "Name of the staging bucket"
  value = google_storage_bucket.staging.name
}

output "processor_service_account" {
  description = "Email of the processor service account"
  value = google_service_account.processor.email
}

output "splitter_service_account" {
  description = "Email of the file splitter service account"
  value = google_service_account.splitter.email
}

output "eventarc_invoker_service_account" {
  description = "Email of the Eventarc invoker service account"
  value = google_service_account.eventarc_invoker.email
}
