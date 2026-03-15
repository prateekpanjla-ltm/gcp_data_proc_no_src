# Phase 4 Monitoring — First Time Setup
# Enable APIs, grant dashboard SA read access to BQ

# logging.googleapis.com is always enabled by default and is a dependency for
# Cloud Run, Cloud Build, Cloud Functions etc. No need for Phase 4 to manage it.
# Removing avoids stale state issues on destroy (see learnings Issue 17).
# resource "google_project_service" "logging" {
#   project            = var.project_id
#   service            = "logging.googleapis.com"
#   disable_on_destroy = false
# }

# Dashboard SA needs to run queries and read the pipeline_logs dataset
resource "google_project_iam_member" "dashboard_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${var.dashboard_sa_email}"
}

resource "google_bigquery_dataset_iam_member" "dashboard_data_viewer" {
  project    = var.project_id
  dataset_id = var.pipeline_logs_dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${var.dashboard_sa_email}"
}

# Clean up stale deleted SA entries from github_archive dataset IAM
# When Phase 4 is destroyed and recreated, the old SA gets a "deleted:" prefix
# in existing dataset IAM bindings, which blocks new IAM grants.
resource "null_resource" "cleanup_stale_sa_bindings" {
  # Always run — stale entries may exist from a previous destroy/recreate cycle
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command     = <<-SCRIPT
      echo "Checking for stale SA bindings in github_archive dataset..."
      STALE=$(bq show --format=prettyjson ${var.project_id}:github_archive 2>/dev/null | grep -o '"deleted:serviceAccount:${var.dashboard_sa_email}?uid=[0-9]*"' | head -1)
      if [ -n "$STALE" ]; then
        MEMBER=$(echo $STALE | tr -d '"')
        echo "Found stale binding: $MEMBER"
        echo "Removing..."
        bq query --project_id=${var.project_id} --nouse_legacy_sql \
          "REVOKE \`roles/bigquery.dataViewer\` ON SCHEMA \`${var.project_id}.github_archive\` FROM \"$MEMBER\""
        echo "Stale SA binding removed."
      else
        echo "No stale SA bindings found."
      fi
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# Dashboard SA needs to read github_archive dataset for Phase 3 row counts
resource "google_bigquery_dataset_iam_member" "dashboard_github_archive_viewer" {
  depends_on = [null_resource.cleanup_stale_sa_bindings]

  project    = var.project_id
  dataset_id = "github_archive"
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${var.dashboard_sa_email}"
}

# Verify dashboard SA actually has BQ permissions after IAM grant
resource "null_resource" "verify_dashboard_iam" {
  depends_on = [
    google_bigquery_dataset_iam_member.dashboard_github_archive_viewer,
    google_bigquery_dataset_iam_member.dashboard_data_viewer,
    google_project_iam_member.dashboard_bq_job_user,
    google_project_iam_member.dashboard_bq_resource_viewer,
  ]

  triggers = {
    dashboard_sa_email = var.dashboard_sa_email
  }

  provisioner "local-exec" {
    command     = <<-SCRIPT
      MAX_ATTEMPTS=6
      for i in $(seq 1 $MAX_ATTEMPTS); do
        echo "Verifying dashboard SA IAM (attempt $i/$MAX_ATTEMPTS)..."
        TOKEN=$(gcloud auth print-access-token --impersonate-service-account=${var.dashboard_sa_email} 2>/dev/null)
        if [ -n "$TOKEN" ]; then
          STATUS=$(curl -s -o /dev/null -w "%%{http_code}" \
            -H "Authorization: Bearer $TOKEN" \
            "https://bigquery.googleapis.com/bigquery/v2/projects/${var.project_id}/datasets/github_archive?fields=id")
          if [ "$STATUS" = "200" ]; then
            echo "IAM verified: dashboard SA can access github_archive dataset."
            exit 0
          else
            echo "  Access not yet propagated (HTTP $STATUS)"
          fi
        else
          echo "  Could not impersonate SA, waiting..."
        fi
        sleep 10
      done
      echo "WARNING: IAM verification timed out after 60s. Dashboard may need a few more minutes."
      exit 0
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# Dashboard SA needs to query INFORMATION_SCHEMA.JOBS for Phase 3 load job details
resource "google_project_iam_member" "dashboard_bq_resource_viewer" {
  project = var.project_id
  role    = "roles/bigquery.resourceViewer"
  member  = "serviceAccount:${var.dashboard_sa_email}"
}
