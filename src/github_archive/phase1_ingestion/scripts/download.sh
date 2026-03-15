#!/bin/bash
#
# GitHub Archive Download Script for Cloud Run Job
# Downloads hourly GitHub Archive file to Cloud Storage
#
# Environment Variables:
#   ENVIRONMENT  - Environment: dev|test|prod (default: dev)
#   PROJECT_ID   - Google Cloud Project ID (required)
#   BUCKET_NAME  - Target Cloud Storage bucket name (optional, auto-derived)
#
set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
BUCKET_NAME="${BUCKET_NAME:-${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing}"

FILENAME="$(date -u -d '-1 hour' '+%Y-%m-%d-%-H').json.gz"
TARGET_PATH="gs://${BUCKET_NAME}/github-archive/raw/${FILENAME}"
SOURCE_URL="https://data.gharchive.org/${FILENAME}"

echo "=== GitHub Archive Download Job ==="
echo "Environment: ${ENVIRONMENT}"
echo "Filename: ${FILENAME}"
echo "Source URL: ${SOURCE_URL}"
echo "Bucket: ${BUCKET_NAME}"
echo "Project: ${PROJECT_ID}"

# ==============================================================================
# Check if file already exists (idempotency)
# ==============================================================================

if gsutil -q stat "${TARGET_PATH}" 2>/dev/null; then
  echo "File already exists, skipping download"
  exit 0
fi

echo "File does not exist, proceeding with download"

# ==============================================================================
# Download and upload to GCS
# ==============================================================================

echo "Starting download from GitHub Archive..."

if curl -fsSL "${SOURCE_URL}" | gsutil cp - "${TARGET_PATH}"; then
  FILE_SIZE=$(gsutil du "${TARGET_PATH}" | awk '{print $1}')
  echo "Download completed: ${TARGET_PATH} (${FILE_SIZE} bytes)"
else
  echo "Download failed" >&2
  exit 1
fi
