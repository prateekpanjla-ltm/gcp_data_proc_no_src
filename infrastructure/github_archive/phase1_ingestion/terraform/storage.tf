# Cloud Storage for Phase 1: GitHub Archive Ingestion

# ==============================================================================
# GitHub Archive Landing Bucket (Phase 1: Raw Ingestion)
# ==============================================================================
# Raw GitHub Archive files are downloaded here directly from GitHub Archive
# Uses gsutil streaming for memory-efficient download
resource "google_storage_bucket" "github_archive_landing" {
  name          = local.github_archive.bucket_name
  project       = var.project_id
  location      = var.region
  force_destroy = var.environment == "dev" ? true : var.force_destroy

  uniform_bucket_level_access = true

  # Auto-delete files after specified days
  lifecycle_rule {
    condition {
      age = var.bucket_lifecycle_days
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    environment = var.environment
    source      = "github-archive"
    layer       = "landing"
    phase       = "ingestion"
    managed_by  = "terraform"
  }
}
