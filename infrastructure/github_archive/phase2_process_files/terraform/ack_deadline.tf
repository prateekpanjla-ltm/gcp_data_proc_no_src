# Phase 2: Eventarc Pub/Sub Ack Deadline Override
# Eventarc creates Pub/Sub subscriptions with 10s ack deadline by default.
# File processing can take minutes, so we increase to 600s (max) to prevent
# duplicate message delivery (Error 16 in learnings).

resource "null_resource" "update_trigger_ack_deadline" {
  depends_on = [google_eventarc_trigger.main_file_processor]

  triggers = {
    trigger_name = google_eventarc_trigger.main_file_processor.name
  }

  provisioner "local-exec" {
    command     = <<-SCRIPT
      gcloud auth activate-service-account --key-file=${var.deployer_sa_key_path} || exit 1
      SUB=$(gcloud eventarc triggers describe ${google_eventarc_trigger.main_file_processor.name} \
        --location ${var.region} \
        --project=${var.project_id} \
        --format='value(transport.pubsub.subscription)')
      gcloud pubsub subscriptions update "$SUB" --ack-deadline=600 --project=${var.project_id}
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
