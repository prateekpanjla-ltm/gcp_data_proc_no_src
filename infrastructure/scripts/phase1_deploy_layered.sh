#!/bin/bash
# Deploy Phase 1: GitHub Archive Ingestion - Layered Approach
# Usage: ./phase1_deploy_layered.sh [PROJECT_ID] [ENVIRONMENT] [REGION] [LAYER]
#
# Examples:
#   ./phase1_deploy_layered.sh dev-dataprocessing-489305 dev us-central1 layer1    # Layer 1 only
#   ./phase1_deploy_layered.sh dev-dataprocessing-489305 dev us-central1 layer2    # Layer 2 only
#   ./phase1_deploy_layered.sh dev-dataprocessing-489305 dev us-central1 layer3    # Layer 3 only
#   ./phase1_deploy_layered.sh dev-dataprocessing-489305 dev us-central1 all       # All layers
#
# Layers:
#   layer1 - Foundation: Service Accounts, IAM Bindings, GCS Bucket
#   layer2 - Compute: Cloud Run Job
#   layer3 - Automation: Cloud Scheduler
#   all    - Deploy all layers sequentially

set -e

# =============================================================================
# Change to project root directory (script location independent execution)
# =============================================================================
# Get script's directory, then navigate to project root (one level up from infrastructure/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "${SCRIPT_DIR}")")"
cd "${PROJECT_ROOT}"

echo "Project root: ${PROJECT_ROOT}"
echo ""

# =============================================================================
# Logging Setup
# =============================================================================
LOG_DIR="${PROJECT_ROOT}/infrastructure/scripts/logs"
TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/phase1-layered-${TS}.log"

# Create logs directory if it doesn't exist
mkdir -p "${LOG_DIR}"

# Redirect all output to both console and log file
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

echo "========================================="
echo "Log file: ${LOG_FILE}"
echo "========================================="
echo ""

# =============================================================================
# Argument Validation
# =============================================================================
PROJECT_ID="${1:-${PROJECT_ID}}"
ENVIRONMENT="${2:-dev}"
REGION="${3:-us-central1}"
LAYER="${4:-all}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: PROJECT_ID not set."
  echo "Usage: $0 <PROJECT_ID> [ENVIRONMENT] [REGION] [LAYER]"
  echo "   or: PROJECT_ID=your-project-id $0"
  echo ""
  echo "Layers:"
  echo "  layer1 - Foundation: Service Accounts, IAM, GCS Bucket"
  echo "  layer2 - Compute: Cloud Run Job"
  echo "  layer3 - Automation: Cloud Scheduler"
  echo "  all    - Deploy all layers (default)"
  exit 1
fi

# =============================================================================
# Terraform Configuration
# =============================================================================
TERRAFORM_DIR="${PROJECT_ROOT}/infrastructure/github_archive/phase1_ingestion/terraform"
SA_ID="${ENVIRONMENT}-terraform-deployer"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_FILE="${PROJECT_ROOT}/infrastructure/secrets/terraform/${SA_ID}-${PROJECT_ID}.json"

# =============================================================================
# Layer Definitions
# =============================================================================
declare -A LAYER_NAMES=(
  ["1"]="Foundation"
  ["2"]="Compute"
  ["3"]="Automation"
)
declare -A LAYER_RESOURCES=(
  ["1"]="Service Accounts, IAM Bindings, GCS Bucket"
  ["2"]="Cloud Run Job"
  ["3"]="Cloud Scheduler"
)
declare -A LAYER_TARGETS=(
  ["1"]="google_service_account.github_archive_downloader google_service_account.scheduler google_project_iam_member.github_archive_downloader_storage google_project_iam_member.github_archive_downloader_logging google_storage_bucket.github_archive_landing"
  ["2"]="google_cloud_run_v2_job.github_archive_downloader"
  ["3"]="google_cloud_run_v2_job_iam_member.scheduler_github_invoker google_cloud_scheduler_job.github_archive_download"
)

# =============================================================================
# Banner
# =============================================================================
echo "========================================="
echo "Phase 1: GitHub Archive Ingestion - Layered Deployment"
echo "========================================="
echo "Project:     ${PROJECT_ID}"
echo "Environment: ${ENVIRONMENT}"
echo "Region:      ${REGION}"
echo "Layer:       ${LAYER}"
echo "SA Email:    ${SA_EMAIL}"
echo "Started at:  $(date)"
echo "========================================="
echo ""

# =============================================================================
# Pre-flight Checks
# =============================================================================
echo "Step 1: Pre-flight checks..."
echo ""

# Check if key file exists
if [[ ! -f "${KEY_FILE}" ]]; then
  echo "  ✗ Key file not found: ${KEY_FILE}"
  echo "  Run: ./create-terraform-deployer-account.sh ${PROJECT_ID} ${ENVIRONMENT}"
  exit 1
fi
echo "  ✓ Key file found: ${KEY_FILE}"

# Check if Terraform directory exists
if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "  ✗ Terraform directory not found: ${TERRAFORM_DIR}"
  exit 1
fi
echo "  ✓ Terraform directory found: ${TERRAFORM_DIR}"

# Check gcloud authentication
if ! gcloud auth list --filter="status:ACTIVE" >/dev/null 2>&1; then
  echo "  ⚠ No active gcloud session found"
  echo "  Note: Using service account key instead (recommended)"
fi

echo ""

# =============================================================================
# Terraform Directory (using -chdir option instead of cd)
# =============================================================================
echo "Terraform directory: ${TERRAFORM_DIR}"
echo ""

# =============================================================================
# Export credentials
# =============================================================================
echo "Step 2: Setting credentials..."
export GOOGLE_APPLICATION_CREDENTIALS="${KEY_FILE}"
echo "  ✓ GOOGLE_APPLICATION_CREDENTIALS=${KEY_FILE}"
echo ""

# =============================================================================
# Terraform Initialize
# =============================================================================
echo "Step 3: Initializing Terraform..."
if terraform -chdir="${TERRAFORM_DIR}" init > /dev/null 2>&1; then
  echo "  ✓ Terraform initialized"
else
  echo "  ✗ Terraform init failed"
  exit 1
fi
echo ""

# =============================================================================
# Function to deploy a layer
# =============================================================================
deploy_layer() {
  local layer_num=$1
  local layer_name="${LAYER_NAMES[$layer_num]}"
  local resources="${LAYER_RESOURCES[$layer_num]}"
  local targets="${LAYER_TARGETS[$layer_num]}"

  echo "========================================="
  echo "Layer ${layer_num}: ${layer_name}"
  echo "========================================="
  echo "Resources: ${resources}"
  echo ""

  # Create plan for this layer only
  echo "Creating plan for Layer ${layer_num}..."
  plan_file="${LOG_DIR}/phase1-layer${layer_num}-${TS}.tfplan"

  # Build target flags for each resource
  target_flags=""
  for target in $targets; do
    target_flags="$target_flags -target=$target"
  done

  if terraform -chdir="${TERRAFORM_DIR}" plan \
    -out="${plan_file}" \
    -var="project_id=${PROJECT_ID}" \
    -var="environment=${ENVIRONMENT}" \
    -var="region=${REGION}" \
    $target_flags 2>/dev/null; then
    echo "  ✓ Plan created: ${plan_file}"
  else
    echo "  ✗ Plan failed for Layer ${layer_num}"
    return 1
  fi
  echo ""

  # Show what will be created
  echo "Planned changes for Layer ${layer_num}:"
  terraform -chdir="${TERRAFORM_DIR}" show "${plan_file}" 2>/dev/null | grep -A3 "Plan:" || true
  echo ""

  # Prompt for confirmation
  if [[ "${AUTO_CONFIRM:-}" != "true" ]]; then
    read -p "Apply Layer ${layer_num} (${layer_name})? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Layer ${layer_num} skipped by user."
      echo ""
      return 0
    fi
  fi

  # Apply this layer
  echo "Applying Layer ${layer_num}..."
  if terraform -chdir="${TERRAFORM_DIR}" apply "${plan_file}"; then
    echo ""
    echo "  ✅ Layer ${layer_num} (${layer_name}) deployed successfully!"
  else
    echo ""
    echo "  ❌ Layer ${layer_num} deployment failed!"
    return 1
  fi
  echo ""
}

# =============================================================================
# Function to show verification commands
# =============================================================================
show_verification() {
  local layer_num=$1

  echo "========================================="
  echo "Verification Commands - Layer ${layer_num}"
  echo "========================================="
  echo ""

  case $layer_num in
    1)
      echo "Verify Service Accounts:"
      echo "  gcloud iam service-accounts list --project=${PROJECT_ID} --filter=\"github-archive\""
      echo ""
      echo "Verify GCS Bucket:"
      echo "  gsutil ls gs://${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing"
      echo ""
      echo "Verify IAM Bindings:"
      echo "  gcloud projects get-iam-policy ${PROJECT_ID} --filter=\"github-archive\""
      ;;
    2)
      echo "Verify Cloud Run Job:"
      echo "  gcloud run jobs list --project=${PROJECT_ID} --filter=\"github-archive\""
      echo ""
      echo "Test Cloud Run Job manually (DO THIS before Layer 3):"
      echo "  gcloud run jobs execute ${ENVIRONMENT}-github-archive-download-gsutil --region=${REGION}"
      echo ""
      echo "View job logs:"
      echo "  gcloud logging logs tail --resource=projects/${PROJECT_ID}/locations/${REGION}/jobs/${ENVIRONMENT}-github-archive-download-gsutil"
      ;;
    3)
      echo "Verify Cloud Scheduler:"
      echo "  gcloud scheduler jobs list --project=${PROJECT_ID} --location=${REGION} --filter=\"github-archive\""
      echo ""
      echo "Check scheduler status:"
      echo "  gcloud scheduler jobs describe ${ENVIRONMENT}-github-archive-download-job --location=${REGION} --project=${PROJECT_ID}"
      echo ""
      echo "View recent executions:"
      echo "  gcloud run jobs executions list ${ENVIRONMENT}-github-archive-download-gsutil --region=${REGION} --limit=5"
      ;;
  esac
  echo ""
}

# =============================================================================
# Deploy Layers
# =============================================================================
case "${LAYER}" in
  "layer1")
    deploy_layer 1
    show_verification 1
    ;;
  "layer2")
    deploy_layer 2
    show_verification 2
    ;;
  "layer3")
    deploy_layer 3
    show_verification 3
    ;;
  "all")
    # Layer 1: Foundation
    if deploy_layer 1; then
      show_verification 1

      echo "========================================="
      echo "⚠️  PAUSE: Verify Layer 1 before continuing"
      echo "========================================="
      echo "Run the verification commands above to ensure Layer 1 is working."
      echo ""
      read -p "Press Enter to continue to layer2, or Ctrl+C to exit..."
      echo ""
    else
      echo "❌ Layer 1 failed. Exiting."
      exit 1
    fi

    # Layer 2: Compute
    if deploy_layer 2; then
      show_verification 2

      echo "========================================="
      echo "⚠️  PAUSE: Test Cloud Run Job before enabling Scheduler"
      echo "========================================="
      echo "IMPORTANT: Test the Cloud Run Job manually BEFORE proceeding to layer3:"
      echo ""
      echo "  gcloud run jobs execute ${ENVIRONMENT}-github-archive-download-gsutil --region=${REGION}"
      echo ""
      echo "Only proceed to layer3 after confirming the job works correctly."
      echo ""
      read -p "Press Enter to continue to layer3, or Ctrl+C to exit..."
      echo ""
    else
      echo "❌ Layer 2 failed. Exiting."
      exit 1
    fi

    # Layer 3: Automation
    if deploy_layer 3; then
      show_verification 3
    else
      echo "❌ Layer 3 failed."
      exit 1
    fi

    # Final Summary
    echo "========================================="
    echo "✅ Phase 1 Deployment Complete!"
    echo "========================================="
    echo ""
    echo "Completed at: $(date)"
    echo "Log saved to: ${LOG_FILE}"
    echo ""
    echo "All Layers Deployed:"
    echo "  ✓ Layer 1: Foundation (SAs, IAM, GCS)"
    echo "  ✓ Layer 2: Compute (Cloud Run Job)"
    echo "  ✓ Layer 3: Automation (Cloud Scheduler)"
    echo ""
    echo "Next Steps:"
    echo "  1. Monitor the first scheduled execution"
    echo "  2. Check Cloud Logging for job execution logs"
    echo "  3. Verify files appear in GCS bucket"
    ;;
  *)
    echo "Error: Invalid layer '${LAYER}'"
    echo "Valid options: layer1, layer2, layer3, or all"
    exit 1
    ;;
esac
