# Layer 03: Operational Outputs

output "processor_service_url" {
  description = "URL of the processor Cloud Run Service"
  value       = "https://${google_cloud_run_v2_service.processor.name}-${var.project_id}.${var.region}.run.app"
}

output "processor_service_name" {
  description = "Name of the processor Cloud Run Service"
  value       = google_cloud_run_v2_service.processor.name
}

output "storage_trigger_name" {
  description = "Name of the Eventarc trigger for storage events"
  value       = google_eventarc_trigger.storage_events.name
}

output "image_deployed" {
  description = "Docker image tag deployed"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.environment}-github-archive/processor:${var.image_tag}"
}

output "deployment_timestamp" {
  description = "Timestamp when this configuration was applied"
  value       = timestamp()
}
