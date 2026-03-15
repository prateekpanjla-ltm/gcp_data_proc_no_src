#!/bin/bash
# Deploy All Phases of GitHub Archive Pipeline
# Usage: ./deploy-all-phases.sh <PROJECT_ID> <ENVIRONMENT> [REGION]
#
# Deploys Phase 1 -> Phase 2 -> Phase 3 -> Phase 4 (Layer 01 -> 02 -> 03) in sequence.
# Each phase depends on outputs from the previous phase.
#
# Example:
#   ./deploy-all-phases.sh beaming-glyph-489707-b8 test us-central1

set -euo pipefail

# =============================================================================
# Arguments & Defaults
# =============================================================================
PROJECT_ID="${1:?Error: PROJECT_ID required. Usage: $0 <PROJECT_ID> <ENVIRONMENT> [REGION]}"
ENVIRONMENT="${2:?Error: ENVIRONMENT required (dev/test/prod)}"
REGION="${3:-us-central1}"

# =============================================================================
# Paths
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASE="${REPO_ROOT}/infrastructure/github_archive"
KEY_PATH="${REPO_ROOT}/infrastructure/${ENVIRONMENT}-terraform-deployer-key.json"

# Fallback key paths
if [[ ! -f "${KEY_PATH}" ]]; then
  KEY_PATH="${REPO_ROOT}/infrastructure/test-terraform-deployer-key.json"
fi
if [[ ! -f "${KEY_PATH}" && -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  KEY_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"
fi

# =============================================================================
# Logging
# =============================================================================
LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/deploy-all-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# =============================================================================
# Derived Names
# =============================================================================
LANDING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing"
STAGING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-staging"

# =============================================================================
# Pre-flight
# =============================================================================
echo "========================================="
echo "GitHub Archive Pipeline - Full Deploy"
echo "========================================="
echo "Project:     ${PROJECT_ID}"
echo "Environment: ${ENVIRONMENT}"
echo "Region:      ${REGION}"
echo "Key File:    ${KEY_PATH}"
echo "Log File:    ${LOG_FILE}"
echo "Started:     $(date)"
echo "========================================="
echo ""

if [[ ! -f "${KEY_PATH}" ]]; then
  echo "ERROR: Service account key not found: ${KEY_PATH}"
  echo "Run setup-terraform-deployer.sh first."
  exit 1
fi

export GOOGLE_APPLICATION_CREDENTIALS="${KEY_PATH}"

# Helper function for terraform apply
tf_apply() {
  local dir="$1"
  shift
  echo "  terraform init..."
  terraform -chdir="${dir}" init -input=false -no-color
  echo "  terraform apply..."
  terraform -chdir="${dir}" apply -auto-approve -input=false "$@"
}

DEPLOY_START=$(date +%s)

# =============================================================================
# Phase 1: Ingestion
# =============================================================================
echo ""
echo "========================================="
echo "Phase 1: Ingestion"
echo "========================================="
PHASE1_DIR="${BASE}/phase1_ingestion/terraform"

tf_apply "${PHASE1_DIR}" \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="region=${REGION}" \
  -var="force_destroy=true" \
  -var="deployer_sa_key_path=${KEY_PATH}"

echo ""
echo "  Phase 1 complete. Landing bucket: ${LANDING_BUCKET}"

# =============================================================================
# Phase 2: Process Files
# =============================================================================
echo ""
echo "========================================="
echo "Phase 2: Process Files"
echo "========================================="
PHASE2_DIR="${BASE}/phase2_process_files/terraform"

tf_apply "${PHASE2_DIR}" \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="landing_bucket_name=${LANDING_BUCKET}" \
  -var="deployer_sa_key_path=${KEY_PATH}"

echo ""
echo "  Phase 2 complete. Staging bucket: ${STAGING_BUCKET}"

# =============================================================================
# Phase 3: BigQuery Loader (3 layers)
# =============================================================================
echo ""
echo "========================================="
echo "Phase 3: BigQuery Loader"
echo "========================================="
PHASE3_BASE="${BASE}/phase3_loadbigquery/terraform/layers"

# Layer 01: Static
echo ""
echo "--- Layer 01: Static ---"
tf_apply "${PHASE3_BASE}/01_static" \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="region=${REGION}"

# Layer 02: First-time
echo ""
echo "--- Layer 02: First-time ---"
tf_apply "${PHASE3_BASE}/02_first_time" \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="region=${REGION}" \
  -var="staging_bucket_name=${STAGING_BUCKET}"

# Layer 03: Operational
echo ""
echo "--- Layer 03: Operational ---"
tf_apply "${PHASE3_BASE}/03_operational" \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="staging_bucket_name=${STAGING_BUCKET}"

# =============================================================================
# Phase 4: Monitoring Dashboard (3 layers)
# =============================================================================
echo ""
echo "========================================="
echo "Phase 4: Monitoring Dashboard"
echo "========================================="
PHASE4_BASE="${BASE}/phase4_monitoring/terraform/layers"
DASHBOARD_SA="${ENVIRONMENT}-pipeline-dashboard@${PROJECT_ID}.iam.gserviceaccount.com"
PIPELINE_LOGS_DATASET="${ENVIRONMENT}_pipeline_logs"

# Layer 01: Static
echo ""
echo "--- Layer 01: Static ---"
tf_apply "${PHASE4_BASE}/01_static" \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}"

# Layer 02: First-time (includes stale SA cleanup + IAM verification)
echo ""
echo "--- Layer 02: First-time ---"
terraform -chdir="${PHASE4_BASE}/02_first_time" init -upgrade -input=false -no-color
echo "  terraform apply..."
terraform -chdir="${PHASE4_BASE}/02_first_time" apply -auto-approve -input=false \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="dashboard_sa_email=${DASHBOARD_SA}" \
  -var="pipeline_logs_dataset_id=${PIPELINE_LOGS_DATASET}"

# Layer 03: Operational (includes Cloud Build + Cloud Run)
echo ""
echo "--- Layer 03: Operational ---"
terraform -chdir="${PHASE4_BASE}/03_operational" init -upgrade -input=false -no-color
echo "  terraform apply..."
terraform -chdir="${PHASE4_BASE}/03_operational" apply -auto-approve -input=false \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="dashboard_sa_email=${DASHBOARD_SA}" \
  -var="pipeline_logs_dataset_id=${PIPELINE_LOGS_DATASET}" \
  -var="artifact_registry_repo=${ENVIRONMENT}-github-archive" \
  -var="deployer_sa_key_path=${KEY_PATH}"

echo ""
echo "  Phase 4 complete."

# =============================================================================
# Summary
# =============================================================================
DEPLOY_END=$(date +%s)
DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))

DASHBOARD_URL=$(terraform -chdir="${PHASE4_BASE}/03_operational" output -raw dashboard_url 2>/dev/null || echo "N/A")

echo ""
echo "========================================="
echo "Deploy Complete"
echo "========================================="
echo "Duration:       ${DEPLOY_DURATION}s"
echo "Landing Bucket: ${LANDING_BUCKET}"
echo "Staging Bucket: ${STAGING_BUCKET}"
echo "BQ Dataset:     ${PROJECT_ID}:github_archive.github_events"
echo "Dashboard:      ${DASHBOARD_URL}"
echo "Log:            ${LOG_FILE}"
echo "Finished:       $(date)"
echo "========================================="
