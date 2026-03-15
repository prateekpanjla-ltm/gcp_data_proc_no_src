# Layer 02: First-time Resources
# These resources require APIs to be enabled first
# Apply once, re-apply only if changes are needed
#
# NOTE: Service Agent IAM bindings moved to Layer 02
# These require APIs to be enabled first (eventarc, bigquery, storage.googleapis.com)

# =============================================================================
# Data Sources - Remote State from Layer 01
# =============================================================================
data "terraform_remote_state" "static" {
  backend = "gcs"
  config = {
    bucket = "beaming-glyph-489707-b8-terraform-state"
    prefix = "terraform/state/phase3-static"
  }
}

# =============================================================================
# Locals
# =============================================================================
locals {
  env_prefix = var.environment
  common_labels = {
    environment = var.environment
    phase       = "bigquery_loader"
    managed_by  = "terraform"
    layer       = "first_time"
  }
}

# =============================================================================
# IAM: BigQuery Data Editor (on dataset)
# =============================================================================
resource "google_bigquery_dataset_iam_member" "bq_loader_data_editor" {
  dataset_id = var.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${data.terraform_remote_state.static.outputs.service_account_email_bq_loader}"
  depends_on = [data.terraform_remote_state.static]
}

# NOTE: bq_loader_job_user (project-level) is already in Layer 01
# Removed duplicate to avoid Terraform conflict

# =============================================================================
# IAM: Storage Object Viewer (staging bucket)
# =============================================================================
resource "google_storage_bucket_iam_member" "bq_loader_staging_viewer" {
  bucket = var.staging_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.terraform_remote_state.static.outputs.service_account_email_bq_loader}"
  depends_on = [data.terraform_remote_state.static]
}

# =============================================================================
# IAM: Storage Object Admin (for deleting files after load)
# =============================================================================
resource "google_storage_bucket_iam_member" "bq_loader_staging_admin" {
  bucket = var.staging_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.terraform_remote_state.static.outputs.service_account_email_bq_loader}"
  depends_on = [data.terraform_remote_state.static]
}

# =============================================================================
# IAM: Eventarc SA needs objectViewer on staging bucket (Learnings Issue 2)
# =============================================================================
# Eventarc service agent needs to validate the bucket exists when creating trigger
data "google_project" "current" {
  project_id = var.project_id
}

resource "google_storage_bucket_iam_member" "eventarc_sa_staging_viewer" {
  bucket = var.staging_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-eventarc.iam.gserviceaccount.com"
}

# NOTE: Cloud Run IAM binding moved to Layer 03 (operational)
# The IAM binding for the Cloud Run service must be created after the service exists.
# Layer 03 creates the Cloud Run service and then applies the IAM binding.
