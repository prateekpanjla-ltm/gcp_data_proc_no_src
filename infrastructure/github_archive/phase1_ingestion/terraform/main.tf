# Phase 1: GitHub Archive Ingestion Only
# This configuration deploys only the resources needed for Phase 1:
# - Service Account for downloading
# - Cloud Run Job (gsutil-based downloader)
# - Cloud Scheduler Job (hourly trigger)
# - GCS Landing Bucket

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # Backend for state management (configure per environment)
  backend "gcs" {
    bucket = "beaming-glyph-489707-b8-terraform-state"
    prefix = "terraform/state/phase1-ingestion"
  }
}

# Provider configuration
provider "google" {
  project         = var.project_id
  region          = var.region
  request_timeout = "120s"
}
