# Grant the downloader service account permission to read container images
# from Artifact Registry. This is required for the Cloud Run Job to start.
resource "google_project_iam_member" "downloader_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.github_archive_downloader.email}"
}