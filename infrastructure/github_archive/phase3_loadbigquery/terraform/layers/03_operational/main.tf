# Layer 03: Operational Resources
# Cloud Functions 2nd gen for BigQuery load triggered by GCS events
#
# This layer creates:
# - Cloud Functions 2nd gen function with built-in Eventarc trigger
# - Source bucket for function code
# - IAM for GCS service account (pubsub.publisher)
#
# Dependencies:
# - Layer 01_static: Service accounts, BigQuery dataset
# - Layer 02_first_time: IAM bindings for bq_loader SA

# =============================================================================
# Data Sources - Remote State
# =============================================================================
data "terraform_remote_state" "static" {
  backend = "gcs"
  config = {
    bucket = "beaming-glyph-489707-b8-terraform-state"
    prefix = "terraform/state/phase3-static"
  }
}

data "terraform_remote_state" "first_time" {
  backend = "gcs"
  config = {
    bucket = "beaming-glyph-489707-b8-terraform-state"
    prefix = "terraform/state/phase3-first-time"
  }
}

# Get GCS service account for Pub/Sub publishing
data "google_storage_project_service_account" "gcs_account" {
}

# Get project info
data "google_project" "project" {
}

# =============================================================================
# Locals
# =============================================================================
locals {
  env_prefix      = var.environment
  function_name   = "${local.env_prefix}-bq-loader"
  source_bucket   = "${var.project_id}-${local.env_prefix}-gcf-source"
  common_labels = {
    environment = var.environment
    phase       = "bigquery_loader"
    managed_by  = "terraform"
    layer       = "operational"
  }
}

# =============================================================================
# IAM: GCS Service Account needs Pub/Sub Publisher for events
# =============================================================================
# Required for GCS to publish events to Pub/Sub (used by Eventarc)
resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# =============================================================================
# IAM: bq_loader SA needs Artifact Registry reader for Cloud Build
# =============================================================================
resource "google_project_iam_member" "bq_loader_artifactregistry" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${data.terraform_remote_state.static.outputs.service_account_email_bq_loader}"
}

# =============================================================================
# IAM: Eventarc invoker SA needs run.invoker for Cloud Functions 2nd gen
# =============================================================================
# Cloud Functions 2nd gen runs on Cloud Run, so the trigger SA needs invoker role
resource "google_project_iam_member" "eventarc_invoker_run" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${data.terraform_remote_state.static.outputs.service_account_email_eventarc_invoker}"
}

# NOTE: Cloud Build SA (${environment}-cloud-build) already has
# roles/cloudbuild.builds.builder from Phase 1 (includes AR writer + storage admin)

# =============================================================================
# Storage: Source bucket for function code
# =============================================================================
resource "google_storage_bucket" "source" {
  name                        = local.source_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = contains(["dev", "test"], var.environment)

  labels = local.common_labels
}

# =============================================================================
# Storage: Upload function source code
# =============================================================================
resource "google_storage_bucket_object" "source" {
  name   = "function-source-${filemd5("${path.module}/../../../../../../src/github_archive/phase3_loadbigquery/main.py")}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.function_source.output_path

  depends_on = [data.archive_file.function_source]
}

# Archive the function source code
data "archive_file" "function_source" {
  type        = "zip"
  output_path = "${path.module}/function-source.zip"
  source_dir  = "${path.module}/../../../../../../src/github_archive/phase3_loadbigquery"
}

# =============================================================================
# Cloud Functions 2nd gen: BigQuery Loader
# =============================================================================
resource "google_cloudfunctions2_function" "bq_loader" {
  name        = local.function_name
  location    = var.region
  description = "Loads processed GitHub Archive files from GCS to BigQuery"

  labels = local.common_labels

  # Wait for IAM permissions to propagate
  depends_on = [
    google_project_iam_member.gcs_pubsub_publisher,
    google_project_iam_member.bq_loader_artifactregistry,
    google_project_iam_member.eventarc_invoker_run,
  ]

  build_config {
    runtime         = "python311"
    entry_point     = "load_to_bigquery"
    service_account = "projects/${var.project_id}/serviceAccounts/${var.environment}-cloud-build@${var.project_id}.iam.gserviceaccount.com"

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.source.name
      }
    }

    environment_variables = {
      BUILD_ENV = var.environment
    }
  }

  service_config {
    max_instance_count  = var.max_instances
    min_instance_count  = 0
    available_memory    = var.function_memory
    timeout_seconds     = var.function_timeout
    available_cpu       = "1"

    environment_variables = {
      PROJECT_ID        = var.project_id
      DATASET_ID        = var.dataset_id
      TABLE_ID          = var.table_id
      DELETE_AFTER_LOAD = tostring(var.delete_after_load)
    }

    ingress_settings                = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision  = true
    service_account_email           = data.terraform_remote_state.static.outputs.service_account_email_bq_loader
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.storage.object.v1.finalized"
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = data.terraform_remote_state.static.outputs.service_account_email_eventarc_invoker

    event_filters {
      attribute = "bucket"
      value     = var.staging_bucket_name
    }
  }
}
