#!/bin/bash
# Enable required Google Cloud APIs for Phase 1 deployment
# Usage: ./scripts/enable-apis.sh [PROJECT_ID]
#
# Example:
#   ./scripts/enable-apis.sh dev-dataprocessing-489305

set -e

# =============================================================================
# Logging Setup
# =============================================================================
LOG_DIR="logs"
LOG_FILE="${LOG_DIR}/enable-apis-$(date +%Y%m%d-%H%M%S).log"

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
# Project ID Validation
# =============================================================================
PROJECT_ID="${1:-${PROJECT_ID}}"
if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: PROJECT_ID not set."
  echo "Usage: $0 <PROJECT_ID>"
  echo "   or: PROJECT_ID=your-project-id $0"
  exit 1
fi

echo "========================================="
echo "Enabling APIs for project: ${PROJECT_ID}"
echo "Started at: $(date)"
echo "========================================="
echo ""

# =============================================================================
# Enable APIs
# =============================================================================
# Required APIs for Phase 1
APIS=(
  "cloudbuild.googleapis.com"       # Cloud Build - build container images
  "run.googleapis.com"              # Cloud Run - create/manage jobs
  "cloudscheduler.googleapis.com"   # Cloud Scheduler - scheduled jobs
  "iam.googleapis.com"              # IAM - create service accounts
  "artifactregistry.googleapis.com" # Artifact Registry - store container images
  "cloudresourcemanager.googleapis.com" # Cloud Resource Manager - required by Terraform
)

echo "Enabling APIs..."
for api in "${APIS[@]}"; do
  echo "  - Enabling ${api}..."
  if gcloud services enable "${api}" --project="${PROJECT_ID}"; then
    echo "    ✓ ${api} enabled successfully"
  else
    echo "    ✗ Failed to enable ${api}"
  fi
  echo ""
done

# =============================================================================
# Verification
# =============================================================================
echo "========================================="
echo "Verifying enabled APIs..."
echo "========================================="
echo ""

gcloud services list --enabled --project="${PROJECT_ID}" --filter="name:cloudbuild.googleapis.com OR name:run.googleapis.com OR name:cloudscheduler.googleapis.com OR name:iam.googleapis.com OR name:artifactregistry.googleapis.com"

echo ""
echo "========================================="
echo "APIs enabled successfully!"
echo "Completed at: $(date)"
echo "Log saved to: ${LOG_FILE}"
echo "========================================="
