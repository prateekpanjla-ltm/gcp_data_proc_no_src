# Local values for Phase 1: GitHub Archive Ingestion naming conventions

locals {
  # Environment prefix for resource naming
  env_prefix = var.environment

  # GitHub Archive Ingestion Resource Names
  github_archive = {
    # Service Account: dev-github-archive-downloader
    service_account_id = "${local.env_prefix}-github-archive-downloader"

    # Storage Bucket: {project_id}-dev-github-archive-landing
    bucket_name = "${var.project_id}-${local.env_prefix}-github-archive-landing"

    # Cloud Run Job: dev-github-archive-download-gsutil
    job_name = "${local.env_prefix}-github-archive-download-gsutil"

    # Cloud Scheduler: dev-github-archive-download-job
    scheduler_name = "${local.env_prefix}-github-archive-download-job"
  }

  # GCS path prefix for landing zone
  gcs_paths = {
    github_landing = "github-archive/raw"
  }
}
