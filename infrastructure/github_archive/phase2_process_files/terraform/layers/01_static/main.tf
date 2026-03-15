# Layer 01: Static Resources
# These resources rarely change after initial deployment
# Apply once, re-apply only when IAM/bucket changes are needed

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  backend "gcs" {
    bucket = "beaming-glyph-489707-b8-terraform-state"
    prefix = "terraform/state/phase2-static"
  }
  # Using local backend for development
}

provider "google" {
  project         = var.project_id
  region          = var.region
  request_timeout = "120s"
}

# =============================================================================
# Data Source
# =============================================================================
data "google_project" "current" {
  project_id = var.project_id
}

# =============================================================================
# Locals
# =============================================================================
locals {
  env_prefix = var.environment

  phase2_resources = {
    processor_service_account = "${local.env_prefix}-github-archive-processor"
    splitter_service_account   = "${local.env_prefix}-file-splitter"
    eventarc_invoker           = "${local.env_prefix}-eventarc-invoker"
    staging_bucket             = "${var.project_id}-${local.env_prefix}-github-archive-staging"
  }

  common_labels = {
    environment = var.environment
    phase       = "processing"
    managed_by  = "terraform"
    layer       = "static"
  }
}

# =============================================================================
# Service Accounts
# =============================================================================
resource "google_service_account" "processor" {
  account_id   = local.phase2_resources.processor_service_account
  display_name = "${title(var.environment)} GitHub Archive Processor"
  description  = "Service account for Cloud Run Service that processes GitHub Archive files (both raw and chunks)"
}

resource "google_service_account" "splitter" {
  account_id   = local.phase2_resources.splitter_service_account
  display_name = "${title(var.environment)} File Splitter"
  description  = "Service account for Cloud Run Job that splits large files"
}

resource "google_service_account" "eventarc_invoker" {
  account_id   = local.phase2_resources.eventarc_invoker
  display_name = "${title(var.environment)} Eventarc Invoker"
  description  = "Service account for Eventarc trigger authentication"
}

# =============================================================================
# Staging Bucket
# =============================================================================
resource "google_storage_bucket" "staging" {
  name          = local.phase2_resources.staging_bucket
  location      = var.region
  project       = var.project_id
  force_destroy = var.environment == "dev"

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = var.staging_retention_days
    }
    action {
      type = "Delete"
    }
  }

  labels = local.common_labels
}

# =============================================================================
# IAM: Project-Level
# =============================================================================
# Processor SA - Logging and monitoring
resource "google_project_iam_member" "processor_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.processor.email}"
}

resource "google_project_iam_member" "processor_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.processor.email}"
}

# Splitter SA - Logging and monitoring
resource "google_project_iam_member" "splitter_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.splitter.email}"
}

resource "google_project_iam_member" "splitter_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.splitter.email}"
}

# Eventarc Invoker SA - Logging (required for Eventarc to write trigger logs)
resource "google_project_iam_member" "eventarc_invoker_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.eventarc_invoker.email}"
}

# =============================================================================
# Note: Service Agent IAM bindings moved to Layer 02
# These require APIs to be enabled first (eventarc.googleapis.com, storage.googleapis.com)
# =============================================================================
# IAM: Bucket-Level (Least Privilege)
# =============================================================================
# Processor SA: Read from landing bucket, write to staging bucket
resource "google_storage_bucket_iam_member" "processor_landing_read" {
  bucket = var.landing_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.processor.email}"
}

resource "google_storage_bucket_iam_member" "processor_staging_write" {
  bucket = google_storage_bucket.staging.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.processor.email}"
}

# Processor SA: Read from staging bucket (to check if files exist, read temp files, blob.reload())
# NOTE: objectViewer includes storage.objects.get which is needed for blob.reload() after uploads
# See learnings/phase2_blob_reload_403_error.md for troubleshooting 403 errors
resource "google_storage_bucket_iam_member" "processor_staging_read" {
  bucket = google_storage_bucket.staging.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.processor.email}"
}

# Splitter SA: Read from landing/raw, write to landing/chunks
resource "google_storage_bucket_iam_member" "splitter_landing_read" {
  bucket = var.landing_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.splitter.email}"
}

resource "google_storage_bucket_iam_member" "splitter_landing_chunks_write" {
  bucket = var.landing_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.splitter.email}"
}
