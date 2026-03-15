# Phase 2: Process Files - Cloud Build for Processor Image
# Builds and pushes the processor Docker image to Artifact Registry.
# The AR repo and Cloud Build SA are created in Phase 1.

resource "null_resource" "build_processor_image" {
  # Rebuild when source code changes
  triggers = {
    dockerfile_hash   = filesha256("${path.module}/../../../../src/github_archive/phase2_process_files/Dockerfile.processor")
    requirements_hash = filesha256("${path.module}/../../../../src/github_archive/phase2_process_files/requirements.txt")
    cloudbuild_config = filesha256("${path.module}/../../../../config/cloudbuild-phase2.yaml")
  }

  provisioner "local-exec" {
    command     = <<-SCRIPT
      gcloud auth activate-service-account --key-file=${var.deployer_sa_key_path} || exit 1
      gcloud builds submit ${path.module}/../../../../src/github_archive/phase2_process_files \
        --config ${path.module}/../../../../config/cloudbuild-phase2.yaml \
        --project=${var.project_id} \
        --substitutions='_REGION=${var.region},_ENV=${var.environment}' \
        --service-account=projects/${var.project_id}/serviceAccounts/${var.environment}-cloud-build@${var.project_id}.iam.gserviceaccount.com
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
