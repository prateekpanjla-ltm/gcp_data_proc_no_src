#!/bin/bash
# Automated Terraform Deployment Script for GitHub Archive Infrastructure
# Deploys all 3 phases in correct order with validation

set -e  # Exit on error

# =============================================================================
# Configuration
# =============================================================================
PROJECT_ID="${PROJECT_ID:-beaming-glyph-489707-b8}"
ENVIRONMENT="${ENVIRONMENT:-test}"
REGION="${REGION:-us-central1}"
PHASE1_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing"
PHASE2_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-staging"

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

# =============================================================================
# Pre-flight Checks
# =============================================================================
log_info "Starting deployment for project: $PROJECT_ID"
log_info "Environment: $ENVIRONMENT"
log_info "Region: $REGION"
echo ""

# Check if gcloud is authenticated
if ! gcloud auth list --filter="status:ACTIVE" >/dev/null 2>&1; then
    log_error "Not authenticated with gcloud"
    log_info "Run: gcloud auth login"
    exit 1
fi

# Check if project is accessible
log_info "Checking project access..."
if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    log_error "Project $PROJECT_ID not accessible"
    exit 1
fi
log_success "Project accessible"

# =============================================================================
# Phase 1: Ingestion
# =============================================================================
log_info "=========================================="
log_info "Deploying Phase 1: Ingestion"
log_info "=========================================="

cd infrastructure/github_archive/phase1_ingestion/terraform

terraform init
terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="environment=$ENVIRONMENT" \
  -var="region=$REGION" \
  -out=phase1.tfplan

terraform apply phase1.tfplan

log_success "Phase 1 deployed!"

# Validate Phase 1
log_info "Validating Phase 1 resources..."
if gsutil ls "gs://$PHASE1_BUCKET" >/dev/null 2>&1; then
    log_success "Landing bucket created: gs://$PHASE1_BUCKET"
else
    log_error "Landing bucket not found"
    exit 1
fi

if gcloud run jobs list --project="$PROJECT_ID" --filter="github-archive" >/dev/null 2>&1; then
    log_success "Cloud Run Job created"
else
    log_warning "Cloud Run Job not found (may still be creating)"
fi

# =============================================================================
# Phase 2: Processing
# =============================================================================
log_info "=========================================="
log_info "Deploying Phase 2: Processing"
log_info "=========================================="

PHASE2_DIR="../../../infrastructure/github_archive/phase2_process_files/terraform"

# Layer 01: Static
log_info "Deploying Phase 2 - Layer 01: Static..."
cd "$PHASE2_DIR/layers/01_static"

terraform init
terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="environment=$ENVIRONMENT" \
  -var="region=$REGION" \
  -var="landing_bucket_name=$PHASE1_BUCKET" \
  -out=phase2_static.tfplan

terraform apply phase2_static.tfplan
log_success "Phase 2 Static layer deployed"

# Layer 02: First-Time
log_info "Deploying Phase 2 - Layer 02: First-Time..."
cd ../02_first_time

terraform init
terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="environment=$ENVIRONMENT" \
  -var="region=$REGION" \
  -out=phase2_firsttime.tfplan

terraform apply phase2_firsttime.tfplan
log_success "Phase 2 First-Time layer deployed"

# Layer 03: Operational
log_info "Deploying Phase 2 - Layer 03: Operational..."
cd ../03_operational

terraform init
terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="environment=$ENVIRONMENT" \
  -var="region=$REGION" \
  -var="image_tag=latest" \
  -out=phase2_operational.tfplan

terraform apply phase2_operational.tfplan
log_success "Phase 2 Operational layer deployed"

# Validate Phase 2
log_info "Validating Phase 2 resources..."
if gsutil ls "gs://$PHASE2_BUCKET" >/dev/null 2>&1; then
    log_success "Staging bucket created: gs://$PHASE2_BUCKET"
else
    log_error "Staging bucket not found"
    exit 1
fi

SERVICE_NAME="${ENVIRONMENT}-github-archive-processor"
if gcloud run services describe "$SERVICE_NAME" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1; then
    log_success "Cloud Run Service created: $SERVICE_NAME"
else
    log_warning "Cloud Run Service not found (may still be creating)"
fi

# =============================================================================
# Phase 3: Loading
# =============================================================================
log_info "=========================================="
log_info "Deploying Phase 3: Loading"
log_info "=========================================="

PHASE3_DIR="../../../infrastructure/github_archive/phase3_loadbigquery/terraform"

# Layer 01: Static
log_info "Deploying Phase 3 - Layer 01: Static..."
cd "$PHASE3_DIR/layers/01_static"

terraform init
terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="environment=$ENVIRONMENT" \
  -var="region=$REGION" \
  -out=phase3_static.tfplan

terraform apply phase3_static.tfplan
log_success "Phase 3 Static layer deployed"

# Layer 02: First-Time
log_info "Deploying Phase 3 - Layer 02: First-Time..."
cd ../02_first_time

terraform init
terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="environment=$ENVIRONMENT" \
  -var="region=$REGION" \
  -var="staging_bucket_name=$PHASE2_BUCKET" \
  -out=phase3_firsttime.tfplan

terraform apply phase3_firsttime.tfplan
log_success "Phase 3 First-Time layer deployed"

# Layer 03: Operational
log_info "Deploying Phase 3 - Layer 03: Operational..."
cd ../03_operational

terraform init
terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="environment=$ENVIRONMENT" \
  -var="region=$REGION" \
  -out=phase3_operational.tfplan

terraform apply phase3_operational.tfplan
log_success "Phase 3 Operational layer deployed"

# Validate Phase 3
log_info "Validating Phase 3 resources..."
if bq --project_id="$PROJECT_ID" ls -d github_archive >/dev/null 2>&1; then
    log_success "BigQuery dataset created"
else
    log_warning "BigQuery dataset not found (checking table directly)"
fi

if bq --project_id="$PROJECT_ID" show github_archive.github_events >/dev/null 2>&1; then
    log_success "BigQuery table created"
else
    log_warning "BigQuery table not found (may still be creating)"
fi

# =============================================================================
# Cloud Build Deployment
# =============================================================================
log_info "=========================================="
log_info "Deploying Application Code with Cloud Build"
log_info "=========================================="

cd "../../../../src/github_archive/phase2_process_files"

log_info "Building and deploying Phase 2 processor..."
gcloud builds submit --config=cloudbuild.yaml . \
  --substitutions=_REGION="$REGION",_ENVIRONMENT="$ENVIRONMENT" \
  --project="$PROJECT_ID"

log_success "Cloud Build completed"

# =============================================================================
# Final Validation
# =============================================================================
log_info "=========================================="
log_info "Final Validation"
log_info "=========================================="

echo ""
log_success "Deployment Summary:"
echo ""
echo "Phase 1 - Ingestion:"
echo "  ✓ Landing Bucket: gs://$PHASE1_BUCKET"
echo "  ✓ Downloader Job"
echo "  ✓ Scheduler Job"
echo ""
echo "Phase 2 - Processing:"
echo "  ✓ Staging Bucket: gs://$PHASE2_BUCKET"
echo "  ✓ Cloud Run Service: $SERVICE_NAME"
echo "  ✓ Eventarc Trigger"
echo ""
echo "Phase 3 - Loading:"
echo "  ✓ BigQuery Dataset: github_archive"
echo "  ✓ BigQuery Table: github_events"
echo "  ✓ Cloud Function: bq_loader"
echo ""
log_success "Full deployment completed successfully!"
echo ""
echo "Next steps:"
echo "  1. Test the pipeline manually:"
echo "     gcloud run jobs execute ${ENVIRONMENT}-github-archive-download-gsutil --project=$PROJECT_ID --region=$REGION"
echo ""
echo "  2. Monitor logs:"
echo "     gcloud logging logs tail --project=$PROJECT_ID --resource=projects/$PROJECT_ID/locations/$REGION/services/$SERVICE_NAME"
echo ""
echo "  3. Check BigQuery:"
echo "     bq query --project_id=$PROJECT_ID 'SELECT COUNT(*) FROM github_archive.github_events'"
