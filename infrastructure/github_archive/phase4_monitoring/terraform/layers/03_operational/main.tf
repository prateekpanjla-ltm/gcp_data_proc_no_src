# Phase 4 Monitoring — Operational Resources
# Log sink exporting pipeline logs to BigQuery
# Cloud Run service for dashboard UI

# Log sink: exports logs from all 3 phases to BQ
resource "google_logging_project_sink" "pipeline_logs" {
  name        = "${var.environment}-github-archive-pipeline-logs"
  project     = var.project_id
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${var.pipeline_logs_dataset_id}"

  # Filter: all 3 phase services
  filter = <<-EOT
    (resource.type="cloud_run_job" OR resource.type="cloud_run_revision" OR resource.type="cloud_function")
    AND (resource.labels.service_name=~"github-archive" OR resource.labels.job_name=~"github-archive")
  EOT

  # Use partitioned tables for cost-efficient queries
  bigquery_options {
    use_partitioned_tables = true
  }
}

# Grant the log sink's auto-generated writer identity access to the BQ dataset
resource "google_bigquery_dataset_iam_member" "log_sink_auto_writer" {
  project    = var.project_id
  dataset_id = var.pipeline_logs_dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.pipeline_logs.writer_identity
}

# Build and push dashboard Docker image to Artifact Registry
resource "null_resource" "build_dashboard_image" {
  # Rebuild when source code changes
  triggers = {
    dockerfile_hash   = filesha256("${path.module}/../../../../../../src/github_archive/phase4_monitoring/Dockerfile")
    requirements_hash = filesha256("${path.module}/../../../../../../src/github_archive/phase4_monitoring/requirements.txt")
    app_hash          = filesha256("${path.module}/../../../../../../src/github_archive/phase4_monitoring/app.py")
  }

  provisioner "local-exec" {
    command     = <<-SCRIPT
      gcloud auth activate-service-account --key-file=${var.deployer_sa_key_path} || exit 1
      gcloud builds submit ${path.module}/../../../../../../src/github_archive/phase4_monitoring \
        --tag=${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo}/pipeline-dashboard:latest \
        --project=${var.project_id} \
        --service-account=projects/${var.project_id}/serviceAccounts/${var.environment}-cloud-build@${var.project_id}.iam.gserviceaccount.com \
        --default-buckets-behavior=REGIONAL_USER_OWNED_BUCKET
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# Cloud Run service for dashboard UI
resource "google_cloud_run_v2_service" "dashboard" {
  depends_on = [null_resource.build_dashboard_image]

  name     = "${var.environment}-github-archive-dashboard"
  location = var.region
  project  = var.project_id

  template {
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo}/pipeline-dashboard:latest"

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "DATASET_ID"
        value = var.pipeline_logs_dataset_id
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # cpu_idle = true → request-based billing (CPU throttled when idle)
        # Dashboard is accessed infrequently, cold start acceptable
        cpu_idle = true
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    service_account = var.dashboard_sa_email
  }
}

# Allow unauthenticated access (public dashboard)
# Remove this if you want IAP or IAM-gated access
resource "google_cloud_run_v2_service_iam_member" "dashboard_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.dashboard.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
