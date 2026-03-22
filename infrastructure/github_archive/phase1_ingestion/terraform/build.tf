# Wait for IAM permissions to propagate before submitting Cloud Build.
# GCP IAM is eventually consistent — the policy may be recorded but not yet
# enforced. Unlike the Policy Troubleshooter API (which reads policy documents),
# testIamPermissions checks ACTUAL enforcement by calling the resource APIs
# through the same path as real operations.
#
# Requires: deployer SA must have tokenCreator (project-level) to impersonate
# the Cloud Build SA and call testIamPermissions as that identity.
#
# Checks (all via testIamPermissions as Cloud Build SA):
#   1. Can deployer impersonate Cloud Build SA? (tokenCreator — prerequisite)
#   2. storage.objects.get on _cloudbuild bucket (read build source)
#   3. storage.objects.create on _cloudbuild bucket (write build logs)
#   4. cloudbuild.builds.create on the project (submit builds)
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

      for i in $(seq 1 $MAX_ATTEMPTS); do
        echo "=== IAM enforcement check (attempt $i/$MAX_ATTEMPTS) ==="
        ALL_PASSED=true

        # Check 1: Can deployer impersonate Cloud Build SA?
        # This is the prerequisite — we need a token AS the Cloud Build SA
        # to test its permissions via testIamPermissions.
        TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$SA" 2>/dev/null)
        if [ -n "$TOKEN" ]; then
          echo "  Check 1 (impersonate Cloud Build SA): PASSED"
        else
          echo "  Check 1 (impersonate Cloud Build SA): NOT YET"
          ALL_PASSED=false
        fi

        # Check 2 & 3: testIamPermissions on _cloudbuild bucket
        # Tests actual enforcement — same path as gcloud builds submit uses.
        if [ "$ALL_PASSED" = true ]; then
          STORAGE_PERMS=$(curl -s -H "Authorization: Bearer $TOKEN" \
            "https://storage.googleapis.com/storage/v1/b/$BUCKET/iam/testPermissions?permissions=storage.objects.get&permissions=storage.objects.create&permissions=storage.objects.list" \
            2>/dev/null)

          if echo "$STORAGE_PERMS" | grep -q "storage.objects.get"; then
            echo "  Check 2 (storage.objects.get on $BUCKET): PASSED"
          else
            echo "  Check 2 (storage.objects.get on $BUCKET): NOT YET"
            ALL_PASSED=false
          fi

          if [ "$ALL_PASSED" = true ]; then
            if echo "$STORAGE_PERMS" | grep -q "storage.objects.create"; then
              echo "  Check 3 (storage.objects.create on $BUCKET): PASSED"
            else
              echo "  Check 3 (storage.objects.create on $BUCKET): NOT YET"
              ALL_PASSED=false
            fi
          fi
        fi

        # Check 4: testIamPermissions on the project for cloudbuild.builds.create
        if [ "$ALL_PASSED" = true ]; then
          BUILD_PERMS=$(curl -s -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"permissions":["cloudbuild.builds.create"]}' \
            "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT:testIamPermissions" \
            2>/dev/null)

          if echo "$BUILD_PERMS" | grep -q "cloudbuild.builds.create"; then
            echo "  Check 4 (cloudbuild.builds.create): PASSED"
          else
            echo "  Check 4 (cloudbuild.builds.create): NOT YET"
            ALL_PASSED=false
          fi
        fi

        if [ "$ALL_PASSED" = true ]; then
          echo "=== All IAM enforcement checks passed ==="
          exit 0
        fi

        echo "  Waiting 10s..."
        sleep 10
      done
      echo "ERROR: IAM enforcement timed out after $((MAX_ATTEMPTS * 10))s"
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
