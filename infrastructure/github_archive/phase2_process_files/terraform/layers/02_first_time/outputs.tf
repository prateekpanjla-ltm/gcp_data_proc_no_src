# Layer 02: First-Time Outputs

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

output "artifact_registry_repository" {
  description = "Artifact Registry repository name (defined in Phase 1)"
  value       = "${var.environment}-github-archive"
}

output "docker_repository_name" {
  description = "Name of the Docker repository (defined in Phase 1)"
  value       = "${var.environment}-github-archive"
}

output "apis_enabled" {
  description = "List of enabled APIs"
  value = [
    "eventarc.googleapis.com",
    "eventarcpublishing.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudbuild.googleapis.com"
  ]
}

output "cloud_build_trigger_id" {
  description = "ID of the Cloud Build trigger for Phase 2 processor"
  value       = google_cloudbuild_trigger.phase2_processor.id
}

output "cloud_build_trigger_name" {
  description = "Name of the Cloud Build trigger for Phase 2 processor"
  value       = google_cloudbuild_trigger.phase2_processor.name
}

output "cloud_build_sa_email" {
  description = "Email of the Cloud Build service account (defined in Phase 1)"
  value       = local.cloudbuild_sa_email
}
