#
# Manages the dedicated service account for Cloud Build.
# This SA is used by Cloud Build to build and deploy services across all phases.
# Defined once in Phase 1 and referenced by other phases.
#

resource "google_service_account" "cloudbuild_sa" {
  project      = var.project_id
  account_id   = "${var.environment}-cloud-build"
  display_name = "Service Account for Cloud Build (${var.environment})"
  description  = "Used by Cloud Build to submit builds, push to Artifact Registry, and deploy Cloud Run services/jobs."
}

locals {
  cloud_build_sa_roles = toset([
    # Build, push images, read/write storage (includes artifactregistry.writer + storage.objectAdmin)
    "roles/cloudbuild.builds.builder",

    # Deploy Cloud Run services and jobs
    "roles/run.admin",

    # Deploy Cloud Functions (Phase 3)
    "roles/cloudfunctions.developer",

    # Attach runtime SAs to Cloud Run revisions
    "roles/iam.serviceAccountUser",

    # Write build logs
    "roles/logging.logWriter",
  ])
}

# Grant all required roles to the dedicated Cloud Build service account
resource "google_project_iam_member" "cloudbuild_sa_roles" {
  for_each = local.cloud_build_sa_roles
  project  = var.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}
