resource "google_cloud_run_v2_job" "github_archive_downloader" {
  project  = var.project_id
  name     = "${var.environment}-github-archive-download-gsutil"
  location = var.region

  template {
    template {
      service_account = google_service_account.github_archive_downloader.email
      timeout         = "1800s" # 30 minutes

      containers {
        # This path points to the image built and pushed to Artifact Registry.
        image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.environment}-github-archive/github-archive-downloader:latest"

        env {
          name  = "ENVIRONMENT"
          value = var.environment
        }
        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "BUCKET_NAME"
          value = "${var.project_id}-${var.environment}-github-archive-landing"
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  depends_on = [
    null_resource.build_downloader_image
  ]
}