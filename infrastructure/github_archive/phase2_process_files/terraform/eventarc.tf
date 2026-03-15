# Phase 2: Process Files - Eventarc Trigger
# Single trigger for all files in the landing bucket.
# GCS direct events only support filtering by 'type' and 'bucket' —
# path-based filtering (name attribute) is NOT supported.
# The application code handles routing based on file path (raw/ vs chunks/).

resource "google_eventarc_trigger" "main_file_processor" {
  name     = "${local.env_prefix}-github-archive-storage-trigger"
  location = var.region
  project  = var.project_id

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }
  matching_criteria {
    attribute = "bucket"
    value     = var.landing_bucket_name
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.processor.name
      region  = var.region
    }
  }

  service_account = google_service_account.eventarc_invoker.email

  labels = local.common_labels

  depends_on = [
    google_project_iam_member.storage_pubsub_publisher,
    google_project_iam_member.eventarc_event_receiver,
    google_project_iam_member.eventarc_invoker_event_receiver,
    google_cloud_run_v2_service_iam_member.eventarc_invoker_processor,
    google_service_account_iam_member.pubsub_token_creator_eventarc_invoker,
  ]
}
