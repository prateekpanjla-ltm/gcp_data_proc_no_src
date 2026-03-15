#!/bin/bash
# =============================================================================
# Setup Terraform Deployer Service Account
# =============================================================================
# This script creates a service account with all necessary permissions to deploy
# and manage the GitHub Archive infrastructure across all 3 phases.
#
# Usage:
#   ./setup-terraform-deployer.sh
#
# Environment Variables:
#   PROJECT_ID        - GCP Project ID (required)
#   ENVIRONMENT       - Environment name (default: test)
#   DEPLOYER_SA_ID    - Service account ID (default: <env>-terraform-deployer)
# =============================================================================

set -e  # Exit on error

# =============================================================================
# Configuration
# =============================================================================
PROJECT_ID="${PROJECT_ID:-beaming-glyph-489707-b8}"
ENVIRONMENT="${ENVIRONMENT:-test}"
DEPLOYER_SA_ID="${DEPLOYER_SA_ID:-${ENVIRONMENT}-terraform-deployer}"
DEPLOYER_SA_EMAIL="${DEPLOYER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Functions
# =============================================================================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_command() {
  if ! command -v $1 &> /dev/null; then
    log_error "$1 is not installed"
    exit 1
  fi
}

# =============================================================================
# Pre-flight Checks
# =============================================================================
log_info "=========================================="
log_info "Terraform Deployer Setup"
log_info "=========================================="
echo ""
log_info "Configuration:"
echo "  Project ID:       $PROJECT_ID"
echo "  Environment:      $ENVIRONMENT"
echo "  Deployer SA:      $DEPLOYER_SA_EMAIL"
echo ""

# Check required commands
log_info "Checking prerequisites..."
check_command "gcloud"

# Check for Terraform (optional for setup, required for deployment)
if command -v terraform &> /dev/null; then
    log_success "Terraform is installed ($(terraform version -json | jq -r '.terraform_version' 2>/dev/null || echo 'version unknown'))"
else
    log_warning "Terraform is not installed (required for deployment, but not for this setup)"
    log_info "Install Terraform later: https://developer.hashicorp.com/terraform/downloads"
fi

# Check if gcloud is authenticated
if ! gcloud auth list --filter="status:ACTIVE" >/dev/null 2>&1; then
    log_error "Not authenticated with gcloud"
    log_info "Run: gcloud auth login"
    exit 1
fi

# Check if project is accessible
log_info "Verifying project access..."
if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    log_error "Project $PROJECT_ID not accessible"
    exit 1
fi
log_success "Project accessible"

# Set the project
gcloud config set project "$PROJECT_ID"

# =============================================================================
# Create Service Account
# =============================================================================
log_info "=========================================="
log_info "Creating Service Account"
log_info "=========================================="

# Delete and recreate SA if it already exists
if gcloud iam service-accounts describe "$DEPLOYER_SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
    log_warning "Service account $DEPLOYER_SA_EMAIL already exists, recreating..."
    gcloud iam service-accounts delete "$DEPLOYER_SA_EMAIL" --project="$PROJECT_ID" --quiet || true
fi

log_info "Creating service account: $DEPLOYER_SA_EMAIL"
gcloud iam service-accounts create "$DEPLOYER_SA_ID" \
    --display-name="${ENVIRONMENT} Terraform Deployer" \
    --description="Service account for deploying GitHub Archive infrastructure with Terraform" \
    --project="$PROJECT_ID"
log_success "Service account created"

# =============================================================================
# Grant Project-Level IAM Roles
# =============================================================================
log_info "=========================================="
log_info "Granting Project-Level IAM Roles"
log_info "=========================================="

# Core Terraform permissions
log_info "Granting core Terraform permissions..."

roles=(
    # Compute and networking
    "roles/compute.admin"
    "roles/compute.networkAdmin"
    "roles/compute.securityAdmin"

    # Cloud Run (Jobs and Services)
    "roles/run.admin"
    "roles/run.developer"

    # Cloud Build
    "roles/cloudbuild.builds.builder"
    "roles/cloudbuild.builds.editor"

    # Cloud Functions
    "roles/cloudfunctions.admin"

    # Cloud Storage
    "roles/storage.admin"

    # BigQuery
    "roles/bigquery.admin"

    # IAM and Service Accounts
    "roles/iam.serviceAccountAdmin"
    "roles/resourcemanager.projectIamAdmin"  # Required: Terraform needs this to manage IAM bindings on the project
    "roles/iam.serviceAccountUser"
    "roles/iam.serviceAccountTokenCreator"   # Required: For Cloud Scheduler SA token creation

    # Cloud Scheduler
    "roles/cloudscheduler.admin"

    # Eventarc
    "roles/eventarc.admin"

    # Pub/Sub
    "roles/pubsub.admin"

    # Service Usage (to enable/disable APIs)
    "roles/servicemanagement.serviceViewer"
    "roles/serviceusage.serviceUsageAdmin"

    # Logging and Monitoring
    "roles/logging.logWriter"
    "roles/monitoring.metricWriter"
    "roles/monitoring.admin"

    # Artifact Registry (for container images)
    "roles/artifactregistry.admin"

    # Secret Manager (if using secrets)
    "roles/secretmanager.admin"

    # Project Viewer (for general read access)
    "roles/viewer"
)

for role in "${roles[@]}"; do
    log_info "Granting $role..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$DEPLOYER_SA_EMAIL" \
        --role="$role" \
        --condition=None \
        --quiet 2>/dev/null || log_warning "Failed to grant $role (may already exist)"
done

log_success "Project-level IAM roles granted"

# =============================================================================
# Grant Service Agent Permissions
# =============================================================================
log_info "=========================================="
log_info "Configuring Service Agent Permissions"
log_info "=========================================="

# Get project number for service agent references
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# Allow Terraform to manage Cloud Scheduler service agent
log_info "Configuring Cloud Scheduler service agent..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --quiet 2>/dev/null || log_warning "Cloud Scheduler agent permission already exists"

# Allow Terraform to manage Cloud Storage service agent (for Eventarc)
log_info "Configuring Cloud Storage service agent..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com" \
    --role="roles/pubsub.publisher" \
    --quiet 2>/dev/null || log_warning "Cloud Storage agent permission already exists"

# Allow Terraform to manage Eventarc service agent
log_info "Configuring Eventarc service agent..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com" \
    --role="roles/eventarc.eventReceiver" \
    --quiet 2>/dev/null || log_warning "Eventarc agent permission already exists"

log_success "Service agent permissions configured"

# =============================================================================
# Enable Required APIs
# =============================================================================
log_info "=========================================="
log_info "Enabling Required APIs"
log_info "=========================================="

apis=(
    "cloudresourcemanager.googleapis.com"
    "iam.googleapis.com"
    "compute.googleapis.com"
    "run.googleapis.com"
    "cloudfunctions.googleapis.com"
    "storage.googleapis.com"
    "bigquery.googleapis.com"
    "cloudscheduler.googleapis.com"
    "eventarc.googleapis.com"
    "pubsub.googleapis.com"
    "cloudbuild.googleapis.com"
    "servicemanagement.googleapis.com"
    "serviceusage.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
    "artifactregistry.googleapis.com"
    "secretmanager.googleapis.com"
)

for api in "${apis[@]}"; do
    log_info "Enabling $api..."
    gcloud services enable "$api" --project="$PROJECT_ID" 2>/dev/null || log_warning "$api may already be enabled"
done

log_success "Required APIs enabled"

# =============================================================================
# Grant Permission to ActAs Other Service Accounts
# =============================================================================
log_info "=========================================="
log_info "Configuring Service Account Impersonation"
log_info "=========================================="

# Function to grant actAs permission
grant_actas() {
    local target_sa=$1
    local description=$2

    if gcloud iam service-accounts describe "$target_sa" --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_info "Granting actAs on $description..."
        gcloud iam service-accounts add-iam-policy-binding "$target_sa" \
            --member="serviceAccount:$DEPLOYER_SA_EMAIL" \
            --role="roles/iam.serviceAccountUser" \
            --project="$PROJECT_ID" \
            --quiet 2>/dev/null || log_warning "actAs on $description may already exist"
    else
        log_warning "Service account $target_sa does not exist yet (will be created by Terraform)"
    fi
}

# Grant actAs for service accounts that will be created by Terraform
# These may not exist yet, so we attempt and handle failures gracefully
grant_actas "${ENVIRONMENT}-github-archive-downloader@${PROJECT_ID}.iam.gserviceaccount.com" "GitHub Archive Downloader"
grant_actas "${ENVIRONMENT}-github-archive-processor@${PROJECT_ID}.iam.gserviceaccount.com" "GitHub Archive Processor"
grant_actas "${ENVIRONMENT}-file-splitter@${PROJECT_ID}.iam.gserviceaccount.com" "File Splitter"
grant_actas "${ENVIRONMENT}-eventarc-invoker@${PROJECT_ID}.iam.gserviceaccount.com" "Eventarc Invoker"
grant_actas "${ENVIRONMENT}-bq-loader@${PROJECT_ID}.iam.gserviceaccount.com" "BigQuery Loader"
grant_actas "${ENVIRONMENT}-eventarc-invoker-bq@${PROJECT_ID}.iam.gserviceaccount.com" "Eventarc Invoker BQ"
grant_actas "${ENVIRONMENT}-scheduler@${PROJECT_ID}.iam.gserviceaccount.com" "Scheduler"
grant_actas "${ENVIRONMENT}-cloud-build@${PROJECT_ID}.iam.gserviceaccount.com" "Cloud Build"

log_success "Service account impersonation configured"

# =============================================================================
# Generate and Download Key File
# =============================================================================
log_info "=========================================="
log_info "Generating Service Account Key"
log_info "=========================================="

KEY_FILE="${DEPLOYER_SA_ID}-key.json"

# Overwrite key file if it already exists
if [ -f "$KEY_FILE" ]; then
    log_warning "Key file $KEY_FILE already exists, overwriting..."
    rm -f "$KEY_FILE"
fi

log_info "Creating key file: $KEY_FILE"
gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$DEPLOYER_SA_EMAIL" \
    --project="$PROJECT_ID"
log_success "Key file created: $KEY_FILE"

# Set secure permissions on the key file
log_info "Setting secure permissions on key file..."
chmod 600 "$KEY_FILE"
log_success "Permissions set to 600 (read/write for owner only)"

# Display key file location
echo ""
log_success "Service Account Key Location:"
echo "  File: $KEY_FILE"
echo "  Path: $(pwd)/$KEY_FILE"
echo ""

# Instructions for using the key
log_info "=========================================="
log_info "Authentication Instructions"
log_info "=========================================="
echo ""
log_warning "IMPORTANT SECURITY NOTES:"
echo "  ✓ The key file has been created with secure permissions (600)"
echo "  ✓ This key file contains sensitive credentials"
echo "  ✓ NEVER commit this file to version control"
echo "  ✓ Add this file to your .gitignore immediately"
echo ""
echo "To use this key with Terraform:"
echo ""
echo "  1. Set the environment variable:"
echo "     export GOOGLE_APPLICATION_CREDENTIALS=\$(pwd)/$KEY_FILE"
echo ""
echo "  2. Verify authentication works:"
echo "     gcloud auth application-default print-access-token"
echo ""
echo "  3. For convenience, add to your ~/.bashrc or ~/.zshrc:"
echo "     echo 'export GOOGLE_APPLICATION_CREDENTIALS=/path/to/$KEY_FILE' >> ~/.bashrc"
echo ""

# =============================================================================
# Summary and Next Steps
# =============================================================================
log_info "=========================================="
log_success "Setup Complete!"
log_info "=========================================="
echo ""
log_success "Terraform Deployer Service Account Summary:"
echo ""
echo "  Service Account:  $DEPLOYER_SA_EMAIL"
echo "  Project:          $PROJECT_ID"
echo "  Environment:      $ENVIRONMENT"
echo ""
echo "Permissions granted:"
echo "  ✓ Compute and networking"
echo "  ✓ Cloud Run (Jobs and Services)"
echo "  ✓ Cloud Functions"
echo "  ✓ Cloud Storage"
echo "  ✓ BigQuery"
echo "  ✓ IAM and Service Accounts"
echo "  ✓ Cloud Scheduler"
echo "  ✓ Eventarc"
echo "  ✓ Pub/Sub"
echo "  ✓ Cloud Build"
echo "  ✓ Service Usage"
echo "  ✓ Logging and Monitoring"
echo "  ✓ Artifact Registry"
echo "  ✓ Secret Manager"
echo ""
echo "Key file created and secured:"
echo "  ✓ Location: $(pwd)/$KEY_FILE"
echo "  ✓ Permissions: 600 (owner read/write only)"
echo ""
echo "Next steps:"
echo ""
echo "1. Set the environment variable (required for Terraform):"
echo "   export GOOGLE_APPLICATION_CREDENTIALS=\$(pwd)/$KEY_FILE"
echo ""
echo "2. Verify authentication works:"
echo "   gcloud auth application-default print-access-token"
echo ""
echo "3. Test the setup:"
echo "   cd infrastructure/github_archive/phase1_ingestion/terraform"
echo "   terraform init"
echo "   terraform plan -var=\"project_id=$PROJECT_ID\" -var=\"environment=$ENVIRONMENT\""
echo ""
echo "4. Deploy all phases:"
echo "   export PROJECT_ID=$PROJECT_ID"
echo "   export ENVIRONMENT=$ENVIRONMENT"
echo "   ./infrastructure/deploy-all.sh"
echo ""
log_warning "CRITICAL SECURITY REMINDERS:"
echo "  - Add '$KEY_FILE' to .gitignore immediately"
echo "  - Store this key file securely (it contains sensitive credentials)"
echo "  - NEVER commit this file to version control"
echo "  - Rotate keys regularly (recommended: every 90 days)"
echo "  - Consider using impersonation for production environments"
echo ""
log_success "Setup script completed successfully!"
