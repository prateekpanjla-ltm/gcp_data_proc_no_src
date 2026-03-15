# Phase 2: Process Files - Service Accounts and IAM

# =============================================================================
# Service Accounts
# =============================================================================
resource "google_service_account" "processor" {
  account_id   = local.phase2_resources.processor_service_account
  display_name = "${title(var.environment)} GitHub Archive Processor"
  description  = "Service account for Cloud Run Service that processes GitHub Archive files (both raw and chunks)"
}

resource "google_service_account" "splitter" {
  account_id   = local.phase2_resources.splitter_service_account
  display_name = "${title(var.environment)} File Splitter"
  description  = "Service account for Cloud Run Job that splits large files"
}

resource "google_service_account" "eventarc_invoker" {
  account_id   = local.phase2_resources.eventarc_invoker
  display_name = "${title(var.environment)} Eventarc Invoker"
  description  = "Service account for Eventarc trigger authentication"
}

# =============================================================================
# IAM: Project-Level (minimal, prefer bucket-level)
# =============================================================================
# Note: Using bucket-level IAM where possible for least privilege
# Project-level roles kept to minimum

# Processor SA - Logging and monitoring
resource "google_project_iam_member" "processor_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.processor.email}"
}

resource "google_project_iam_member" "processor_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.processor.email}"
}

# Splitter SA - Logging only
resource "google_project_iam_member" "splitter_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.splitter.email}"
}

# =============================================================================
# IAM: Eventarc Service Agents
# =============================================================================
# Allow Cloud Storage service agent to publish events
# The GCS service agent is created when storage API is enabled
resource "google_project_iam_member" "storage_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.current.number}@gs-project-accounts.iam.gserviceaccount.com"

  depends_on = [null_resource.init_service_agents]
}

# Eventarc service agent
# The Eventarc service agent is created by null_resource.init_service_agents
resource "google_project_iam_member" "eventarc_event_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-eventarc.iam.gserviceaccount.com"

  depends_on = [null_resource.init_service_agents]
}

# =============================================================================
# IAM: Service Account to Service Account
# =============================================================================
# Allow Eventarc invoker to invoke Cloud Run service (Error 17)
resource "google_cloud_run_v2_service_iam_member" "eventarc_invoker_processor" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.processor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.eventarc_invoker.email}"
}

# Eventarc invoker needs eventReceiver role (Error 12)
resource "google_project_iam_member" "eventarc_invoker_event_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.eventarc_invoker.email}"
}

# Pub/Sub SA needs serviceAccountTokenCreator on invoker SA for OIDC tokens (Error 18)
resource "google_service_account_iam_member" "pubsub_token_creator_eventarc_invoker" {
  service_account_id = google_service_account.eventarc_invoker.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
