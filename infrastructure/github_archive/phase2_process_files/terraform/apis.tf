# Phase 2: Process Files - Required APIs
# These APIs must be enabled before creating Eventarc triggers.
# Enabling the APIs also creates the Google-managed service agents.

resource "google_project_service" "eventarc" {
  project = var.project_id
  service = "eventarc.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "pubsub" {
  project = var.project_id
  service = "pubsub.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "run" {
  project = var.project_id
  service = "run.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  project = var.project_id
  service = "storage.googleapis.com"

  disable_on_destroy = false
}

# Initialize service agents (not created automatically by google_project_service)
# These are required before granting IAM to Google-managed service agents
resource "null_resource" "init_service_agents" {
  depends_on = [
    google_project_service.storage,
    google_project_service.eventarc,
  ]

  provisioner "local-exec" {
    command     = <<-SCRIPT
      gcloud auth activate-service-account --key-file=${var.deployer_sa_key_path} || exit 1
      gcloud --quiet beta services identity create --service=storage.googleapis.com --project=${var.project_id}
      gcloud --quiet beta services identity create --service=eventarc.googleapis.com --project=${var.project_id}
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
