# This resource creates the Artifact Registry repository needed for Phase 1.
# Although other documentation suggests this is created in Phase 2, Phase 1
# requires it to push its container image. Adding it here makes Phase 1
# self-contained and deployable independently.

resource "google_artifact_registry_repository" "data_pipeline_repo" {
  project       = var.project_id
  location      = var.region
  repository_id = "${var.environment}-github-archive"
  description   = "Docker repository for data pipeline images"
  format        = "DOCKER"
}