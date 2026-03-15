#!/bin/bash
# Phase 2 Layered Deployment Script for GitHub Archive Processing
# Supports deploying specific layers: static, first-time, operational, or all
#
# Usage: ./phase2_layered_deployment_script.sh [OPTIONS]
#
# Examples:
#   ./phase2_layered_deployment_script.sh --layer all
#   ./phase2_layered_deployment_script.sh --layer operational --image-tag v1.2.3
#   ./phase2_layered_deployment_script.sh --layer static --plan-only

set -e

# =============================================================================
# Change to project root directory (script location independent execution)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$(dirname "${SCRIPT_DIR}")"))"
cd "${PROJECT_ROOT}"

echo "Project root: ${PROJECT_ROOT}"
echo ""

# =============================================================================
# Configuration
# =============================================================================
TERRAFORM_DIR="${PROJECT_ROOT}/infrastructure/github_archive/phase2_process_files/terraform"
SRC_DIR="${PROJECT_ROOT}/src/github_archive/phase2_process_files"
LOG_DIR="${SCRIPT_DIR}/logs"

# Create logs directory if it doesn't exist
mkdir -p "${LOG_DIR}"

# Timestamp for this deployment
TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/phase2-deploy-${TS}.log"

# Redirect all output to both console and log file
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

# =============================================================================
# Banner
# =============================================================================
echo "========================================="
echo "Log file: ${LOG_FILE}"
echo "========================================="
echo ""

# Defaults
PROJECT_ID="${PROJECT_ID:-dev-dataprocessing-489305}"
REGION="${REGION:-us-central1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-terraform-state}"

# Docker image names
PROCESSOR_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/github-archive/processor"

# Layers
LAYER_STATIC="${TERRAFORM_DIR}/layers/01_static"
LAYER_FIRST_TIME="${TERRAFORM_DIR}/layers/02_first_time"
LAYER_OPERATIONAL="${TERRAFORM_DIR}/layers/03_operational"

# =============================================================================
# Functions
# =============================================================================
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    log "ERROR: $1"
    exit 1
}

success() {
    log "SUCCESS: $1"
}

warn() {
    log "WARNING: $1"
}

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Layered Deployment Options:
  --layer all             Deploy all layers (default for first-time setup)
  --layer static          Deploy only Layer 01 (static: SAs, buckets, IAM)
  --layer first-time      Deploy only Layer 02 (first-time: APIs, Artifact Registry)
  --layer operational     Deploy only Layer 03 (operational: Cloud Run, Eventarc)

Other Options:
  --env ENVIRONMENT       Environment: dev or prod (default: dev)
  --image-tag TAG         Docker image tag to deploy (default: latest)
  --skip-build            Skip Docker image build
  --use-cloud-build       Use Cloud Build instead of local Docker (recommended)
  --skip-apply            Skip terraform apply (plan only)
  --plan-only             Only run terraform plan
  --destroy               Destroy resources instead of create/update
  --outputs-only          Show outputs only
  -h, --help              Show this help

Examples:
  # First time setup (all layers) with Cloud Build
  $0 --layer all --use-cloud-build

  # Daily code update using Cloud Build (recommended)
  $0 --layer operational --use-cloud-build

  # Daily code update using local Docker
  $0 --layer operational --image-tag v1.2.3

  # IAM changes (static layer only)
  $0 --layer static

  # Plan changes without applying
  $0 --layer operational --plan-only

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."
    command -v gcloud >/dev/null 2>&1 || error "gcloud is not installed or not in PATH"
    command -v docker >/dev/null 2>&1 || error "Docker is not installed or not in PATH"
    command -v terraform >/dev/null 2>&1 || error "Terraform is not installed or not in PATH"
    success "Prerequisites check passed"
}

init_terraform() {
    local layer_dir=$1
    local layer_name=$2

    log "Initializing Terraform for layer: ${layer_name}..."

    pushd "${layer_dir}" > /dev/null

    # Initialize
    if [ ! -d ".terraform" ]; then
        terraform init \
            -backend-config="bucket=${STATE_BUCKET}"
    else
        terraform init \
            -backend-config="bucket=${STATE_BUCKET}" \
            -reconfigure=false
    fi > /dev/null 2>&1

    # Validate
    terraform validate

    popd > /dev/null

    success "Layer ${layer_name} initialized"
}

apply_layer() {
    local layer_dir=$1
    local layer_name=$2
    local layer_code=$3
    local tfvars_file="${TERRAFORM_DIR}/environments/${ENVIRONMENT}/terraform.tfvars"

    log "Applying layer: ${layer_name}..."

    pushd "${layer_dir}" > /dev/null

    # Build terraform command
    TF_CMD="terraform apply"

    if [ "$PLAN_ONLY" = true ]; then
        TF_CMD="terraform plan"
    fi

    if [ "$SKIP_APPLY" = true ]; then
        TF_CMD="terraform plan"
    fi

    if [ "$DESTROY" = true ]; then
        warn "DESTROY mode enabled - this will delete resources!"
        TF_CMD="terraform destroy"
    fi

    # Timestamped plan file
    plan_file="${LOG_DIR}/phase2-layer${layer_code}-${TS}.tfplan"

    # Run plan first
    log "Creating plan for ${layer_name}..."
    log "Plan file: ${plan_file}"

    if terraform plan \
        -out="${plan_file}" \
        -var="project_id=${PROJECT_ID}" \
        -var="region=${REGION}" \
        -var="environment=${ENVIRONMENT}" \
        -var="terraform_state_bucket=${STATE_BUCKET}" \
        -var-file="${tfvars_file}"; then
        success "Plan created: ${plan_file}"
    else
        error "Plan failed for layer ${layer_name}"
    fi

    # Show plan summary
    log "Plan summary for ${layer_name}:"
    terraform show "${plan_file}" 2>/dev/null | grep -A5 "Plan:" || true

    # Prompt for confirmation (unless auto-approve)
    if [ "$PLAN_ONLY" = false ] && [ "$SKIP_APPLY" = false ] && [ "$AUTO_CONFIRM" != "true" ]; then
        echo ""
        read -p "Apply layer ${layer_code} (${layer_name})? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Layer ${layer_code} skipped by user."
            popd > /dev/null
            return 0
        fi
    fi

    # Apply or show plan
    if [ "$PLAN_ONLY" = true ] || [ "$SKIP_APPLY" = true ]; then
        log "Plan generated (not applied)."
    else
        log "Applying ${layer_name}..."
        if $TF_CMD \
            -var="project_id=${PROJECT_ID}" \
            -var="region=${REGION}" \
            -var="environment=${ENVIRONMENT}" \
            -var="terraform_state_bucket=${STATE_BUCKET}" \
            -var="image_tag=${IMAGE_TAG}" \
            -var-file="${tfvars_file}" \
            "${plan_file}"; then
            success "Layer ${layer_name} applied successfully"
        else
            error "Layer ${layer_name} apply failed"
        fi
    fi

    popd > /dev/null
}

build_docker_images() {
    log "Building Docker images..."

    # Build processor image
    log "Building processor image: ${PROCESSOR_IMAGE}:${IMAGE_TAG}"
    cd "${SRC_DIR}"
    docker build -f Dockerfile.processor -t "${PROCESSOR_IMAGE}:${IMAGE_TAG}" . 2>&1 | while IFS= read -r line; do log "  [docker] $line"; done
    docker tag "${PROCESSOR_IMAGE}:${IMAGE_TAG}" "${PROCESSOR_IMAGE}:latest"
    log "Pushing processor image..."
    docker push "${PROCESSOR_IMAGE}:${IMAGE_TAG}" 2>&1 | while IFS= read -r line; do log "  [docker] $line"; done
    docker push "${PROCESSOR_IMAGE}:latest" 2>&1 | while IFS= read -r line; do log "  [docker] $line"; done

    success "Docker images built and pushed"
}

trigger_cloud_build() {
    log "Triggering Cloud Build for Phase 2 processor..."

    local cloudbuild_config="${SRC_DIR}/cloudbuild.yaml"
    local build_sa="${ENVIRONMENT}-cloud-build@${PROJECT_ID}.iam.gserviceaccount.com"

    # Check if cloudbuild.yaml exists
    if [ ! -f "${cloudbuild_config}" ]; then
        error "cloudbuild.yaml not found at ${cloudbuild_config}"
    fi

    log "Using Cloud Build config: ${cloudbuild_config}"
    log "Service account: ${build_sa}"

    # Get current git commit hash for tagging (if in a git repo)
    local commit_hash="local"
    if git rev-parse --short HEAD &>/dev/null; then
        commit_hash=$(git rev-parse --short HEAD)
    fi

    log "Submitting build to Cloud Build..."
    log "Build source: ${SRC_DIR}"

    # Submit build to Cloud Build
    # Note: SHORT_SHA is automatically provided by Cloud Build
    if gcloud builds submit \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --config="${cloudbuild_config}" \
        --substitutions="_REGION=${REGION},_ENVIRONMENT=${ENVIRONMENT}" \
        --service-account="projects/${PROJECT_ID}/serviceAccounts/${build_sa}" \
        "${SRC_DIR}" 2>&1 | while IFS= read -r line; do log "  [cloud-build] $line"; done; then
        success "Cloud Build completed successfully"
    else
        error "Cloud Build failed"
    fi
}

show_outputs() {
    local layer=$1

    case "$layer" in
        static|01)
            pushd "${LAYER_STATIC}" > /dev/null
            ;;
        first-time|02)
            pushd "${LAYER_FIRST_TIME}" > /dev/null
            ;;
        operational|03)
            pushd "${LAYER_OPERATIONAL}" > /dev/null
            ;;
        all)
            log "=== Layer 01: Static Outputs ==="
            pushd "${LAYER_STATIC}" > /dev/null
            terraform output -json 2>/dev/null || echo "No outputs yet"
            popd > /dev/null

            log "=== Layer 02: First-Time Outputs ==="
            pushd "${LAYER_FIRST_TIME}" > /dev/null
            terraform output -json 2>/dev/null || echo "No outputs yet"
            popd > /dev/null

            log "=== Layer 03: Operational Outputs ==="
            pushd "${LAYER_OPERATIONAL}" > /dev/null
            terraform output -json 2>/dev/null || echo "No outputs yet"
            popd > /dev/null
            return
            ;;
        *)
            error "Unknown layer: $layer"
            ;;
    esac

    terraform output -json 2>/dev/null || echo "No outputs yet"
    popd > /dev/null
}

verify_deployment() {
    log "Verifying deployment..."

    # Check services
    log "Checking Cloud Run services..."
    if gcloud run services list --region="${REGION}" --project="${PROJECT_ID}" --filter="name:github-archive" 2>/dev/null; then
        log "  Cloud Run services found"
    else
        warn "  No Cloud Run services found"
    fi

    # Check triggers
    log "Checking Eventarc triggers..."
    if gcloud eventarc triggers list --region="${REGION}" --project="${PROJECT_ID}" 2>/dev/null; then
        log "  Eventarc triggers found"
    else
        warn "  No Eventarc triggers found"
    fi

    success "Deployment verification complete"
}

show_verification() {
    local layer=$1

    echo ""
    echo "========================================="
    echo "Verification Commands - Layer ${layer}"
    echo "========================================="
    echo ""

    case "$layer" in
        1|static)
            echo "Verify Service Accounts:"
            echo "  gcloud iam service-accounts list --project=${PROJECT_ID} --filter=\"github-archive\""
            echo ""
            echo "Verify GCS Bucket:"
            echo "  gsutil ls gs://${PROJECT_ID}-${ENVIRONMENT}-github-archive-staging"
            echo ""
            echo "Verify IAM Bindings:"
            echo "  gcloud projects get-iam-policy ${PROJECT_ID} --filter=\"github-archive\""
            ;;
        2|first-time)
            echo "Verify APIs Enabled:"
            echo "  gcloud services list --enabled --project=${PROJECT_ID} | grep -E \"eventarc|run\""
            echo ""
            echo "Verify Artifact Registry:"
            echo "  gcloud artifacts repositories list --project=${PROJECT_ID} --location=${REGION}"
            ;;
        3|operational)
            echo "Verify Cloud Run Service:"
            echo "  gcloud run services describe ${ENVIRONMENT}-github-archive-processor --region=${REGION} --project=${PROJECT_ID}"
            echo ""
            echo "Verify Eventarc Triggers:"
            echo "  gcloud eventarc triggers list --region=${REGION} --project=${PROJECT_ID}"
            echo ""
            echo "Test Cloud Run Service:"
            echo "  curl -X POST https://${ENVIRONMENT}-github-archive-processor-${PROJECT_ID}.${REGION}.run.app/health"
            ;;
    esac
    echo ""
}

# =============================================================================
# Main Deployment Flow
# =============================================================================
main() {
    # Parse command line arguments
    LAYER="all"
    SKIP_BUILD=false
    SKIP_APPLY=false
    PLAN_ONLY=false
    DESTROY=false
    OUTPUTS_ONLY=false
    USE_CLOUD_BUILD=false
    IMAGE_TAG="latest"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --layer)
                LAYER="$2"
                shift 2
                ;;
            --env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --image-tag)
                IMAGE_TAG="$2"
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --use-cloud-build)
                USE_CLOUD_BUILD=true
                shift
                ;;
            --skip-apply)
                SKIP_APPLY=true
                shift
                ;;
            --plan-only)
                PLAN_ONLY=true
                shift
                ;;
            --destroy)
                DESTROY=true
                shift
                ;;
            --auto-confirm)
                AUTO_CONFIRM=true
                shift
                ;;
            --outputs-only)
                OUTPUTS_ONLY=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done

    # Outputs only mode
    if [ "$OUTPUTS_ONLY" = true ]; then
        show_outputs "$LAYER"
        exit 0
    fi

    # Header
    log "=========================================="
    log "Phase 2 Layered Deployment"
    log "=========================================="
    log "Project:     ${PROJECT_ID}"
    log "Region:      ${REGION}"
    log "Environment: ${ENVIRONMENT}"
    log "Layer:       ${LAYER}"
    log "Image Tag:   ${IMAGE_TAG}"
    log "Started at:  $(date)"
    log "=========================================="
    echo ""

    check_prerequisites

    # Build Docker images (skip for static/first-time layers unless explicitly requested)
    if [ "$SKIP_BUILD" = false ]; then
        if [ "$LAYER" = "all" ] || [ "$LAYER" = "operational" ] || [ "$LAYER" = "03" ]; then
            if [ "$USE_CLOUD_BUILD" = true ]; then
                log "Using Cloud Build for image build and deployment..."
                trigger_cloud_build
            else
                log "Using local Docker for image build..."
                build_docker_images
            fi
        else
            log "Skipping Docker build for layer: ${LAYER}"
        fi
    fi

    # Apply layers based on selection
    case "$LAYER" in
        all)
            # Layer dependency order: first_time -> static -> operational
            if init_terraform "$LAYER_FIRST_TIME" "first-time"; then
                if apply_layer "$LAYER_FIRST_TIME" "first-time" "02"; then
                    show_verification 2
                else
                    error "Layer 02 (first-time) failed"
                fi
            fi

            echo ""
            log "=========================================="
            log "PAUSE: Verify first-time setup before continuing"
            log "=========================================="
            read -p "Press Enter to continue to static layer, or Ctrl+C to exit..."
            echo ""

            if init_terraform "$LAYER_STATIC" "static"; then
                if apply_layer "$LAYER_STATIC" "static" "01"; then
                    show_verification 1
                else
                    error "Layer 01 (static) failed"
                fi
            fi

            echo ""
            log "=========================================="
            log "PAUSE: Verify static resources before continuing"
            log "=========================================="
            read -p "Press Enter to continue to operational layer, or Ctrl+C to exit..."
            echo ""

            if init_terraform "$LAYER_OPERATIONAL" "operational"; then
                if apply_layer "$LAYER_OPERATIONAL" "operational" "03"; then
                    show_verification 3
                else
                    error "Layer 03 (operational) failed"
                fi
            fi

            # Final Summary
            echo ""
            log "=========================================="
            log "Phase 2 Deployment Complete!"
            log "=========================================="
            log "Completed at: $(date)"
            log "Log saved to: ${LOG_FILE}"
            log ""
            log "All Layers Deployed:"
            log "  ✓ Layer 02: First-Time (APIs, Artifact Registry)"
            log "  ✓ Layer 01: Static (SAs, IAM, GCS)"
            log "  ✓ Layer 03: Operational (Cloud Run, Eventarc)"
            ;;
        static|01)
            if init_terraform "$LAYER_STATIC" "static"; then
                apply_layer "$LAYER_STATIC" "static" "01"
                show_verification 1
            fi
            ;;
        first-time|02)
            if init_terraform "$LAYER_FIRST_TIME" "first-time"; then
                apply_layer "$LAYER_FIRST_TIME" "first-time" "02"
                show_verification 2
            fi
            ;;
        operational|03)
            if init_terraform "$LAYER_OPERATIONAL" "operational"; then
                apply_layer "$LAYER_OPERATIONAL" "operational" "03"
                show_verification 3
            fi
            ;;
        *)
            error "Unknown layer: ${LAYER}. Use: all, static, first-time, or operational"
            ;;
    esac

    # Verify and show outputs
    if [ "$PLAN_ONLY" = false ] && [ "$SKIP_APPLY" = false ] && [ "$DESTROY" = false ]; then
        verify_deployment
        show_outputs "$LAYER"
    fi

    success "Phase 2 deployment complete!"
}

# Run main function
main "$@"
