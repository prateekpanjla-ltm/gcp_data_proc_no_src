#!/bin/bash
# Quick build and push script for Phase 2 code changes
# Use this when you've modified Python code and need to rebuild the container image

set -e

# Configuration
PROJECT_ID="${PROJECT_ID:-dev-dataprocessing-489305}"
REGION="${REGION:-us-central1}"

IMAGE_NAME="${REGION}-docker.pkg.dev/${PROJECT_ID}/github-archive/processor"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../src/github_archive/phase2_process_files" && pwd)"

log() {
    echo "[$(date +'%H:%M:%S')] $1"
}

log "Building processor image from ${SRC_DIR}..."
cd "${SRC_DIR}"

# Build and push
docker build -f Dockerfile.processor -t "${IMAGE_NAME}:latest" .
docker push "${IMAGE_NAME}:latest"

log "Deploying new image to Cloud Run..."
IMAGE_DIGEST=$(docker inspect "${IMAGE_NAME}:latest" --format='{{index .Id}}')

gcloud run services update github-archive-processor \
    --image="${IMAGE_NAME}@${IMAGE_DIGEST}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"

log "Deployment complete!"
log "Service URL: https://github-archive-processor-${PROJECT_ID}.${REGION}.run.app"
