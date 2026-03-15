#!/bin/bash
# Phase 2 Layered Deployment Script for GitHub Archive Processing
# Supports deploying specific layers: static, first-time, operational, or all

set -e

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
SRC_DIR="${SCRIPT_DIR}/../../src/github_archive/phase2_process_files"

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
  --skip-apply            Skip terraform apply (plan only)
  --plan-only             Only run terraform plan
  --destroy               Destroy resources instead of create/update
  --outputs-only          Show outputs only
  -h, --help              Show this help

Examples:
  # First time setup (all layers)
  $0 --layer all

  # Daily code update (operational layer only)
  $0 --layer operational --image-tag v1.2.3

  # IAM changes (static layer only)
  $0 --layer static

  # Plan changes without applying
  $0 --layer operational --plan-only

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check if gcloud is authenticated
    if ! gcloud auth list --filter="account:ACTIVE" 2>/dev/null | grep -q .; then
        error "Not authenticated with gcloud. Run: gcloud auth login"
    fi

    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed"
    fi

    # Check if Terraform is available
    if ! command -v terraform &> /dev/null; then
        error "Terraform is not installed"
    fi

    success "Prerequisites check passed"
}

configure_backend() {
    local layer_dir=$1
    local backend_file="${layer_dir}/backend.tf"

    # Update backend bucket in the layer's backend.tf
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s/REPLACE_WITH_TERRAFORM_STATE_BUCKET/${STATE_BUCKET}/g" "$backend_file"
    else
        # Linux
        sed -i "s/REPLACE_WITH_TERRAFORM_STATE_BUCKET/${STATE_BUCKET}/g" "$backend_file"
    fi
}

init_terraform() {
    local layer_dir=$1
    local layer_name=$2

    log "Initializing Terraform for layer: ${layer_name}..."

    pushd "${layer_dir}" > /dev/null

    # Configure backend before init
    configure_backend "${layer_dir}"

    # Initialize
    if [ ! -d ".terraform" ]; then
        terraform init \
            -backend-config="bucket=${STATE_BUCKET}"
    else
        terraform init \
            -backend-config="bucket=${STATE_BUCKET}" \
            -reconfigure=false
    fi

    # Validate
    terraform validate

    popd > /dev/null

    success "Layer ${layer_name} initialized"
}

apply_layer() {
    local layer_dir=$1
    local layer_name=$2
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

    # Run plan first
    log "Creating plan for ${layer_name}..."
    terraform plan \
        -var="project_id=${PROJECT_ID}" \
        -var="region=${REGION}" \
        -var="environment=${ENVIRONMENT}" \
        -var="terraform_state_bucket=${STATE_BUCKET}" \
        -var-file="${tfvars_file}" \
        -out="tfplan"

    # Apply or show plan
    if [ "$PLAN_ONLY" = true ] || [ "$SKIP_APPLY" = true ]; then
        log "Plan generated (not applied):"
        cat tfplan
    else
        log "Applying ${layer_name}..."
        $TF_CMD \
            -var="project_id=${PROJECT_ID}" \
            -var="region=${REGION}" \
            -var="environment=${ENVIRONMENT}" \
            -var="terraform_state_bucket=${STATE_BUCKET}" \
            -var="image_tag=${IMAGE_TAG}" \
            -var-file="${tfvars_file}" \
            "tfplan"
    fi

    popd > /dev/null

    success "Layer ${layer_name} applied"
}

build_docker_images() {
    log "Building Docker images..."

    # Build processor image
    log "Building processor image..."
    cd "${SRC_DIR}"
    docker build -f Dockerfile.processor -t "${PROCESSOR_IMAGE}:${IMAGE_TAG}" .
    docker tag "${PROCESSOR_IMAGE}:${IMAGE_TAG}" "${PROCESSOR_IMAGE}:latest"
    docker push "${PROCESSOR_IMAGE}:${IMAGE_TAG}"
    docker push "${PROCESSOR_IMAGE}:latest"

    success "Docker images built and pushed"
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
    gcloud run services list --region="${REGION}" --project="${PROJECT_ID}" --filter="name:github-archive" 2>/dev/null || warn "No Cloud Run services found"

    # Check triggers
    log "Checking Eventarc triggers..."
    gcloud eventarc triggers list --region="${REGION}" --project="${PROJECT_ID}" 2>/dev/null || warn "No Eventarc triggers found"

    success "Deployment verification complete"
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
            --outputs-only)
                OUTPUTS_ONLY=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
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
    log "=========================================="

    check_prerequisites

    # Build Docker images (skip for static/first-time layers unless explicitly requested)
    if [ "$SKIP_BUILD" = false ]; then
        if [ "$LAYER" = "all" ] || [ "$LAYER" = "operational" ] || [ "$LAYER" = "03" ]; then
            build_docker_images
        else
            log "Skipping Docker build for layer: ${LAYER}"
        fi
    fi

    # Apply layers based on selection
    case "$LAYER" in
        all)
            # Layer dependency order: first_time -> static -> operational
            init_terraform "$LAYER_FIRST_TIME" "first-time"
            apply_layer "$LAYER_FIRST_TIME" "first-time"

            init_terraform "$LAYER_STATIC" "static"
            apply_layer "$LAYER_STATIC" "static"

            init_terraform "$LAYER_OPERATIONAL" "operational"
            apply_layer "$LAYER_OPERATIONAL" "operational"
            ;;
        static|01)
            init_terraform "$LAYER_STATIC" "static"
            apply_layer "$LAYER_STATIC" "static"
            ;;
        first-time|02)
            init_terraform "$LAYER_FIRST_TIME" "first-time"
            apply_layer "$LAYER_FIRST_TIME" "first-time"
            ;;
        operational|03)
            init_terraform "$LAYER_OPERATIONAL" "operational"
            apply_layer "$LAYER_OPERATIONAL" "operational"
            ;;
        *)
            error "Unknown layer: $LAYER. Use: all, static, first-time, or operational"
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
