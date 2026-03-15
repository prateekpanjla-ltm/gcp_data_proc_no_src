# Phase 2: Process Files - Storage Configuration

# =============================================================================
# Staging Bucket
# =============================================================================
resource "google_storage_bucket" "staging" {
  name          = local.phase2_resources.staging_bucket
  location      = var.region
  project       = var.project_id
  force_destroy = contains(["dev", "test"], var.environment)

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
# Bucket-Level IAM (Least Privilege)
# =============================================================================
# Processor SA: Read from landing bucket, write to staging bucket
resource "google_storage_bucket_iam_member" "processor_landing_read" {
  bucket = var.landing_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.processor.email}"
}

resource "google_storage_bucket_iam_member" "processor_staging_write" {
  bucket = google_storage_bucket.staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.processor.email}"
}

# Processor SA: Read from staging bucket (for blob.reload, checking existing files)
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
