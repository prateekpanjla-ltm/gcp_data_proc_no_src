#!/bin/bash
# Deploy Infrastructure using Terraform Deployer Service Account
# Usage: ./terraform_deploy_using_deployer.sh [PROJECT_ID] [ENVIRONMENT] [REGION]
#
# Example:
#   ./terraform_deploy_using_deployer.sh dev-dataprocessing-489305 dev us-central1

set -e

# =============================================================================
# Logging Setup
# =============================================================================
LOG_DIR="logs"
LOG_FILE="${LOG_DIR}/terraform-deploy-$(date +%Y%m%d-%H%M%S).log"

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

if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: PROJECT_ID not set."
  echo "Usage: $0 <PROJECT_ID> [ENVIRONMENT] [REGION]"
  echo "   or: PROJECT_ID=your-project-id $0"
  exit 1
fi

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
SA_ID="${ENVIRONMENT}-terraform-deployer"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_FILE="${SCRIPT_DIR}/../secrets/terraform/${SA_ID}-${PROJECT_ID}.json"

echo "========================================="
echo "Terraform Deployment"
echo "Project:     ${PROJECT_ID}"
echo "Environment: ${ENVIRONMENT}"
echo "Region:      ${REGION}"
echo "SA Email:     ${SA_EMAIL}"
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
# Change to Terraform directory
# =============================================================================
cd "${TERRAFORM_DIR}"
echo "Working directory: $(pwd)"
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
if terraform init; then
  echo "  ✓ Terraform initialized"
else
  echo "  ✗ Terraform init failed"
  exit 1
fi
echo ""

# =============================================================================
# Terraform Plan
# =============================================================================
echo "Step 4: Creating execution plan..."
echo "  Command: terraform plan -var=\"project_id=${PROJECT_ID}\" -var=\"environment=${ENVIRONMENT}\" -var=\"region=${REGION}\""
echo ""

if terraform plan \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="region=${REGION}"; then
  echo ""
  echo "  ✓ Plan created successfully"
else
  echo ""
  echo "  ✗ Plan failed"
  exit 1
fi
echo ""

# =============================================================================
# Terraform Apply
# =============================================================================
echo "========================================="
echo "Step 5: Applying configuration..."
echo "========================================="
echo ""
echo "Resources to be created/updated:"
echo "  - Service Accounts: 7"
echo "  - Cloud Run Jobs: 5"
echo "  - Cloud Run Services: 2"
echo "  - Cloud Scheduler Jobs: 7"
echo "  - GCS Buckets: 3"
echo "  - BigQuery Datasets: 2"
echo "  - Pub/Sub Topics: 2"
echo "  - Eventarc Triggers: 2"
echo "  - Monitoring Resources: 4"
echo ""
echo "Estimated time: 2-5 minutes"
echo ""
read -p "Continue with apply? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled by user."
  exit 0
fi

echo ""
echo "Applying..."

if terraform apply \
  -var="project_id=${PROJECT_ID}" \
  -var="environment=${ENVIRONMENT}" \
  -var="region=${REGION}" \
  -auto-approve; then
  echo ""
  echo "========================================="
  echo "✅ Deployment Successful!"
  echo "========================================="
  echo ""
  echo "Completed at: $(date)"
  echo "Log saved to: ${LOG_FILE}"
  echo ""
  echo "Next steps:"
  echo "  1. Verify resources: gcloud run jobs list --region=${REGION} --project=${PROJECT_ID}"
  echo "  2. Check scheduler: gcloud scheduler jobs list --project=${PROJECT_ID}"
  echo "  3. View logs: gcloud logging logs tail --resource=projects/${PROJECT_ID}/locations/${REGION}/jobs/*"
else
  echo ""
  echo "========================================="
  echo "❌ Deployment Failed!"
  echo "========================================="
  echo ""
  echo "Check the log file for details: ${LOG_FILE}"
  echo ""
  echo "Common issues:"
  echo "  - API not enabled: ./enable-apis.sh ${PROJECT_ID}"
  echo "  - Insufficient permissions: Check SA roles"
  echo "  - Quota exceeded: Check project quotas"
  exit 1
fi
