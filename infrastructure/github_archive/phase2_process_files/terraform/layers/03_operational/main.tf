# Layer 03: Operational Resources
# These resources change frequently with code updates
# Apply daily/weekly when deploying new code

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
    prefix = "terraform/state/phase2-operational"
  }
  # Using local backend for development
}

provider "google" {
  project         = var.project_id
  region          = var.region
  request_timeout = "120s"
}

# =============================================================================
# Remote State Data Sources (using local backend)
# =============================================================================
data "terraform_remote_state" "static" {
  backend = "gcs"
  config = {
    bucket = "beaming-glyph-489707-b8-terraform-state"
    prefix = "terraform/state/phase2-static"
  }
}

data "terraform_remote_state" "first_time" {
  backend = "gcs"
  config = {
    bucket = "beaming-glyph-489707-b8-terraform-state"
    prefix = "terraform/state/phase2-first-time"
  }
}

# =============================================================================
# Locals
# =============================================================================
locals {
  env_prefix = var.environment

  common_labels = {
    environment = var.environment
    phase       = "processing"
    managed_by  = "terraform"
    layer       = "operational"
  }
}

# =============================================================================
# Cloud Run Service: Processor
# =============================================================================
resource "google_cloud_run_v2_service" "processor" {
  name                = "${local.env_prefix}-github-archive-processor"
  location            = var.region
  project             = var.project_id
  deletion_protection = false                 # Allow deletion without explicit flag
  ingress             = "INGRESS_TRAFFIC_ALL" # Allow external access for testing

  template {
    # Annotations are set directly at template level in v2
    annotations = {
      # Health check
      "run.googleapis.com/health-check-path" = "/health"
    }

    # Execution environment
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

    # Timeout (duration format with 's' suffix)
    timeout = "3600s" # 1 hour

    # TODO: determine safe concurrency for 50MB files with 4GB memory
    # Peak per request: ~300MB decompression + ~100MB pandas chunk + overhead
    # Lower concurrency = more instances needed for bursts = review min-instances (warm) count
    max_instance_request_concurrency = 3

    containers {
      # Image for the processor service
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.environment}-github-archive/processor:${var.image_tag}"

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "LANDING_BUCKET"
        value = data.terraform_remote_state.static.outputs.landing_bucket_name
      }
      env {
        name  = "STAGING_BUCKET"
        value = data.terraform_remote_state.static.outputs.staging_bucket_name
      }
      env {
        name  = "FILE_SIZE_THRESHOLD_MB"
        value = tostring(var.file_size_threshold_mb)
      }
      env {
        name  = "CHUNKSIZE"
        value = tostring(var.chunksize)
      }
      # Note: PORT is automatically set by Cloud Run (reserved env var)

      resources {
        limits = {
          cpu    = tostring(var.processor_cpu)
          memory = "${var.processor_memory}Gi"
        }
        # cpu_idle = true → request-based billing (CPU throttled when idle)
        # Saves ~₹1,400/month vs instance-based (cpu_idle = false)
        # Trade-off: 2-5 second cold start on first request after idle
        cpu_idle = true
      }
    }

    service_account = data.terraform_remote_state.static.outputs.processor_service_account_email
  }

  # Scaling settings at service level
  scaling {
    min_instance_count = 0
    max_instance_count = var.max_instances
  }

  labels = local.common_labels

  # Allow Cloud Build to update the image without Terraform reverting it
  # This separates infrastructure management (Terraform) from application deployment (Cloud Build)
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image
    ]
  }

  depends_on = [
    data.terraform_remote_state.static,
    data.terraform_remote_state.first_time
  ]
}

# =============================================================================
# Eventarc Trigger: Storage events (all files in landing bucket)
# =============================================================================
# NOTE: Cloud Storage Eventarc triggers do NOT support 'name' attribute filtering.
# Only 'type' and 'bucket' attributes are supported for google.cloud.storage.object.v1.finalized.
# Path filtering is done in the Cloud Run service (main.py) instead.
#
# We use a single trigger for the bucket to avoid duplicate Pub/Sub notifications.
resource "google_eventarc_trigger" "storage_events" {
  name     = "${local.env_prefix}-github-archive-storage"
  location = var.region
  project  = var.project_id

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  matching_criteria {
    attribute = "bucket"
    value     = data.terraform_remote_state.static.outputs.landing_bucket_name
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.processor.name
      region  = var.region
    }
  }

  service_account = data.terraform_remote_state.static.outputs.eventarc_invoker_service_account_email

  # Retry policy for transient failures
  # Increased from default to 5 attempts with exponential backoff
  event_data_content_type = "application/json"

  depends_on = [
    data.terraform_remote_state.static,
    data.terraform_remote_state.first_time
  ]

  labels = merge(local.common_labels, { purpose = "storage-trigger" })
}

# =============================================================================
# IAM: Eventarc Invoker -> Cloud Run Service
# =============================================================================
resource "google_cloud_run_v2_service_iam_member" "eventarc_invoker_processor" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.processor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${data.terraform_remote_state.static.outputs.eventarc_invoker_service_account_email}"
}

# =============================================================================
# Eventarc Subscription Ack Deadline
# =============================================================================
# The Eventarc trigger creates a Pub/Sub subscription with a default 10s ack deadline.
# This is too short for file processing. Update to maximum (600s = 10 minutes).
# See: https://cloud.google.com/run/docs/triggering/trigger-with-events#set-ack-deadline
resource "terraform_data" "eventarc_ack_deadline" {
  triggers_replace = [
    google_eventarc_trigger.storage_events.id,
    var.eventarc_ack_deadline_seconds
  ]

  provisioner "local-exec" {
    command = <<EOT
      gcloud pubsub subscriptions update \
        "${google_eventarc_trigger.storage_events.transport[0].pubsub[0].subscription}" \
        --ack-deadline=${var.eventarc_ack_deadline_seconds} \
        --project=${var.project_id}
    EOT
  }

  depends_on = [google_eventarc_trigger.storage_events]
}
