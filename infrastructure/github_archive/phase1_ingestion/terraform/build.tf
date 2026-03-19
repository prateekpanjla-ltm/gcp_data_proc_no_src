# Wait for IAM permissions to propagate before submitting Cloud Build.
# GCP IAM is eventually consistent — the policy may be recorded but not yet
# enforced. Three checks run in sequence:
#   1. Can deployer impersonate Cloud Build SA? (tokenCreator)
#   2. Does Cloud Build SA have cloudbuild.builds.create? (Policy Troubleshooter)
#   3. Does Cloud Build SA have storage.objects.create on build bucket? (Policy Troubleshooter)
# All three must pass before gcloud builds submit runs.
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
      PROJECT="${var.project_id}"
      BUCKET="${var.project_id}_cloudbuild"
      MAX_ATTEMPTS=18

      check_passed() {
        local check_name="$1"
        local result="$2"
        if echo "$result" | grep -q "GRANTED"; then
          echo "  $check_name: GRANTED"
          return 0
        else
          echo "  $check_name: NOT YET"
          return 1
        fi
      }

      for i in $(seq 1 $MAX_ATTEMPTS); do
        echo "=== IAM propagation check (attempt $i/$MAX_ATTEMPTS) ==="
        ALL_PASSED=true

        # Check 1: Can deployer impersonate Cloud Build SA? (tokenCreator)
        TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$SA" 2>/dev/null)
        if [ -n "$TOKEN" ]; then
          echo "  Check 1 (impersonate Cloud Build SA): GRANTED"
        else
          echo "  Check 1 (impersonate Cloud Build SA): NOT YET"
          ALL_PASSED=false
        fi

        # Check 2: Does Cloud Build SA have cloudbuild.builds.create?
        if [ "$ALL_PASSED" = true ]; then
          RESULT2=$(gcloud policy-troubleshoot iam \
            "//cloudresourcemanager.googleapis.com/projects/$PROJECT" \
            --principal-email="$SA" \
            --permission="cloudbuild.builds.create" \
            --format="value(access)" 2>/dev/null)
          check_passed "Check 2 (cloudbuild.builds.create)" "$RESULT2" || ALL_PASSED=false
        fi

        # Check 3: Does Cloud Build SA have storage.objects.create?
        if [ "$ALL_PASSED" = true ]; then
          RESULT3=$(gcloud policy-troubleshoot iam \
            "//storage.googleapis.com/projects/_/buckets/$BUCKET" \
            --principal-email="$SA" \
            --permission="storage.objects.create" \
            --format="value(access)" 2>/dev/null)
          check_passed "Check 3 (storage.objects.create)" "$RESULT3" || ALL_PASSED=false
        fi

        # Check 4: Does Cloud Build SA have storage.objects.get?
        if [ "$ALL_PASSED" = true ]; then
          RESULT4=$(gcloud policy-troubleshoot iam \
            "//storage.googleapis.com/projects/_/buckets/$BUCKET" \
            --principal-email="$SA" \
            --permission="storage.objects.get" \
            --format="value(access)" 2>/dev/null)
          check_passed "Check 4 (storage.objects.get)" "$RESULT4" || ALL_PASSED=false
        fi

        if [ "$ALL_PASSED" = true ]; then
          echo "=== All IAM checks passed ==="
          exit 0
        fi

        echo "  Waiting 10s..."
        sleep 10
      done
      echo "ERROR: IAM propagation timed out after $((MAX_ATTEMPTS * 10))s"
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
