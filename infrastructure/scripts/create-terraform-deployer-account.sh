#!/bin/bash
# Create Terraform Deployer Service Account with Key
# Usage: ./create-terraform-deployer-account.sh [PROJECT_ID] [ENVIRONMENT]
#
# Example:
#   ./create-terraform-deployer-account.sh dev-dataprocessing-489305 dev

set -e

# =============================================================================
# Logging Setup
# =============================================================================
LOG_DIR="logs"
LOG_FILE="${LOG_DIR}/create-terraform-sa-$(date +%Y%m%d-%H%M%S).log"

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

if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: PROJECT_ID not set."
  echo "Usage: $0 <PROJECT_ID> [ENVIRONMENT]"
  echo "   or: PROJECT_ID=your-project-id $0"
  exit 1
fi

SA_ID="${ENVIRONMENT}-terraform-deployer"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "========================================="
echo "Creating Terraform Deployer Service Account"
echo "Project:     ${PROJECT_ID}"
echo "Environment: ${ENVIRONMENT}"
echo "SA ID:       ${SA_ID}"
echo "SA Email:    ${SA_EMAIL}"
echo "Started at:  $(date)"
echo "========================================="
echo ""

# =============================================================================
# Create Service Account
# =============================================================================
echo "Step 1: Creating service account..."
if gcloud iam service-accounts create "${SA_ID}" \
  --display-name="${ENVIRONMENT^} Terraform Deployer" \
  --description="Service account for Terraform infrastructure deployment" \
  --project="${PROJECT_ID}" 2>/dev/null; then
  echo "  ✓ Service account ${SA_ID} created"
else
  echo "  ℹ Service account may already exist, continuing..."
fi
echo ""

# =============================================================================
# Grant Required Roles
# =============================================================================
echo "Step 2: Granting IAM roles..."

# Required roles for Terraform to manage all infrastructure
ROLES=(
  "roles/editor"
  "roles/resourcemanager.projectIamAdmin"
  "roles/iam.serviceAccountAdmin"
  "roles/cloudbuild.builds.builder"
  "roles/run.admin"
  "roles/cloudscheduler.admin"
  "roles/storage.admin"
  "roles/iam.serviceAccountTokenCreator"
  "roles/artifactregistry.admin"
  "roles/bigquery.admin"
  "roles/pubsub.admin"
  "roles/cloudfunctions.admin"
  "roles/monitoring.admin"
  "roles/eventarc.admin"       # Eventarc triggers
  "roles/logging.admin"         # Cloud Logging (monitoring sinks)
)

for role in "${ROLES[@]}"; do
  echo "  - Granting ${role}..."
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None >/dev/null 2>&1
  echo "    ✓ ${role}"
done
echo ""

# =============================================================================
# Create Terraform State Bucket
# =============================================================================
echo "Step 3: Creating terraform remote state bucket..."

STATE_BUCKET="${PROJECT_ID}-terraform-state"

if gsutil ls -b "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  echo "  ℹ Bucket gs://${STATE_BUCKET} already exists"
else
  gsutil mb -l us-central1 -p "${PROJECT_ID}" "gs://${STATE_BUCKET}"
  echo "  ✓ Bucket gs://${STATE_BUCKET} created"
fi

# Enable versioning to protect against accidental state deletion/corruption
gsutil versioning set on "gs://${STATE_BUCKET}" >/dev/null 2>&1
echo "  ✓ Versioning enabled on state bucket"
echo ""

# =============================================================================
# Create Service Account Key
# =============================================================================
echo "Step 4: Creating service account key..."

KEY_DIR="../secrets/terraform"
mkdir -p "${KEY_DIR}"

KEY_FILE="${KEY_DIR}/${SA_ID}-${PROJECT_ID}.json"

# Check if key already exists
if [[ -f "${KEY_FILE}" ]]; then
  echo "  ⚠ Key file already exists: ${KEY_FILE}"
  read -p "  Overwrite existing key? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "  Skipping key creation."
    echo ""
    echo "========================================="
    echo "Using existing key: ${KEY_FILE}"
    echo "========================================="
    exit 0
  fi
  rm -f "${KEY_FILE}"
fi

gcloud iam service-accounts keys create "${KEY_FILE}" \
  --iam-account="${SA_EMAIL}" \
  --project="${PROJECT_ID}"

echo "  ✓ Key created: ${KEY_FILE}"
echo ""

# =============================================================================
# Step 5: Set Key Permissions (security)
# =============================================================================
chmod 600 "${KEY_FILE}"
echo "  ✓ Key permissions set to 600 (owner only)"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo "========================================="
echo "Terraform Service Account Created!"
echo "========================================="
echo ""
echo "Service Account Details:"
echo "  ID:         ${SA_ID}"
echo "  Email:      ${SA_EMAIL}"
echo "  Key File:   ${KEY_FILE}"
echo "  State Bucket: gs://${STATE_BUCKET}"
echo ""
echo "To use with Terraform, set:"
echo "  export GOOGLE_APPLICATION_CREDENTIALS=\"${KEY_FILE}\""
echo ""
echo "Or add to terraform.tfvars:"
echo "  credentials = \"${KEY_FILE}\""
echo ""
echo "Completed at: $(date)"
echo "Log saved to: ${LOG_FILE}"
echo "========================================="
