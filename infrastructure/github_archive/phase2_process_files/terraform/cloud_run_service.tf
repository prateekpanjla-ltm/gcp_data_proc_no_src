# Phase 2: Process Files - Cloud Run Service (v2 Schema)

# =============================================================================
# Single Processor Service (handles both raw/ and chunks/)
# =============================================================================
resource "google_cloud_run_v2_service" "processor" {
  name     = "${local.env_prefix}-github-archive-processor"
  location = var.region
  project  = var.project_id

  # Only internal traffic (Eventarc triggers)
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    # v2: execution environment at template level
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

    # v2: timeout is a duration string, not timeout_seconds
    timeout = "3600s"

    # TODO: determine safe concurrency for 50MB files with 4GB memory
    # Peak per request: ~300MB decompression + ~100MB pandas chunk + overhead
    # Lower concurrency = more instances needed for bursts = review min-instances (warm) count
    # TODO: configure Eventarc dead-letter topic for events that exhaust retries
    max_instance_request_concurrency = 3

    service_account = google_service_account.processor.email

    # v2: scaling inside template block (provider ~5.x)
    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.environment}-github-archive/processor:latest"

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "LANDING_BUCKET"
        value = var.landing_bucket_name
      }
      env {
        name  = "STAGING_BUCKET"
        value = google_storage_bucket.staging.name
      }
      env {
        name  = "FILE_SIZE_THRESHOLD_MB"
        value = tostring(var.file_size_threshold_mb)
      }
      env {
        name  = "CHUNKSIZE"
        value = tostring(var.chunksize)
      }
      # PORT is reserved in Cloud Run v2 - do NOT set it

      resources {
        limits = {
          cpu    = "2"
          memory = "4Gi"
        }
        # cpu_idle = true → request-based billing (CPU throttled when idle)
        # Saves ~₹1,400/month vs instance-based (cpu_idle = false)
        # Trade-off: 2-5 second cold start on first request after idle
        cpu_idle = true
      }
    }
  }

  labels = local.common_labels

  # Image must exist before Cloud Run service can be created
  depends_on = [null_resource.build_processor_image]
}
