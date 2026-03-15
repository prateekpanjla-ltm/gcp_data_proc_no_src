# Wait for IAM permissions to propagate before submitting Cloud Build.
# GCP IAM is eventually consistent — the policy may be recorded but not yet
# enforced. We poll the testIamPermissions API on the Cloud Build source bucket
# to confirm the build SA can actually read/write objects.
resource "null_resource" "wait_for_iam_propagation" {
  depends_on = [
    google_project_iam_member.cloudbuild_sa_roles
  ]

  triggers = {
    sa_email = google_service_account.cloudbuild_sa.email
  }

  provisioner "local-exec" {
    command     = <<-SCRIPT
      SA="${google_service_account.cloudbuild_sa.email}"
      BUCKET="${var.project_id}_cloudbuild"
      MAX_ATTEMPTS=12
      for i in $(seq 1 $MAX_ATTEMPTS); do
        echo "Checking IAM propagation (attempt $i/$MAX_ATTEMPTS)..."
        TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$SA" 2>/dev/null)
        if [ -n "$TOKEN" ]; then
          RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
            "https://storage.googleapis.com/storage/v1/b/$BUCKET/iam/testPermissions?permissions=storage.objects.get&permissions=storage.objects.create")
          if echo "$RESPONSE" | grep -q "storage.objects.get"; then
            echo "IAM permissions confirmed."
            exit 0
          fi
        fi
        echo "  Not yet propagated, waiting 10s..."
        sleep 10
      done
      echo "ERROR: IAM propagation timed out after 120s"
      exit 1
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# This resource automates the container build process during 'terraform apply'.
# It uses a local-exec provisioner to run the 'gcloud builds submit' command,
# ensuring the container image exists before the Cloud Run Job is created.
resource "null_resource" "build_downloader_image" {
  depends_on = [
    google_artifact_registry_repository.data_pipeline_repo,
    null_resource.wait_for_iam_propagation
  ]

  # Re-run whenever source code changes.
  triggers = {
    dockerfile_hash   = filesha256("${path.module}/../../../../src/github_archive/Dockerfile")
    script_hash       = filesha256("${path.module}/../../../../src/github_archive/phase1_ingestion/scripts/download.sh")
    cloudbuild_config = filesha256("${path.module}/../../../../config/cloudbuild-phase1.yaml")
  }

  provisioner "local-exec" {
    command     = <<-SCRIPT
      gcloud auth activate-service-account --key-file=${var.deployer_sa_key_path} || exit 1
      gcloud builds submit ${path.module}/../../../../src/github_archive \
        --config ${path.module}/../../../../config/cloudbuild-phase1.yaml \
        --project=${var.project_id} \
        --substitutions='_REGION=${var.region},_ENV=${var.environment}' \
        --service-account=${google_service_account.cloudbuild_sa.name}
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
