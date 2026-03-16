#!/bin/bash
# =============================================================================
# Phase 4: Monitoring Dashboard - gcloud equivalent
# Includes Log Sink, BigQuery Export, and Build Automation
# =============================================================================

set -e

# Configuration
PROJECT_ID="${PROJECT_ID:-dev-dataprocessing-489305}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REGION="${REGION:-us-central1}"

# Derived Names
DASHBOARD_SA_NAME="${ENVIRONMENT}-github-archive-dashboard"
DASHBOARD_SA_EMAIL="${DASHBOARD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CLOUDBUILD_SA_NAME="${ENVIRONMENT}-cloud-build"
CLOUDBUILD_SA_EMAIL="${CLOUDBUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

PIPELINE_LOGS_DATASET="${ENVIRONMENT}_pipeline_logs"
LOG_SINK_NAME="${ENVIRONMENT}-github-archive-pipeline-logs"
SERVICE_NAME="${ENVIRONMENT}-github-archive-dashboard"
AR_REPO_NAME="${ENVIRONMENT}-github-archive"
CONTAINER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO_NAME}/dashboard:latest"

# Path handling
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Attempt to resolve Project Root to locate source code
if [ -d "${SCRIPT_DIR}/src" ]; then
  PROJECT_ROOT="${SCRIPT_DIR}"
elif [ -d "${SCRIPT_DIR}/../../src" ]; then
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
else
  PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")" # Fallback based on typical infrastructure/scripts path
fi
SOURCE_DIR="${PROJECT_ROOT}/src/github_archive/phase4_monitoring"

echo "Creating Phase 4 infrastructure..."

# 0. Enable APIs
echo "Enabling required APIs..."
gcloud services enable \
    logging.googleapis.com \
    bigquery.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    --project="${PROJECT_ID}"

# 1. Service Accounts
echo "Creating Service Account..."
if ! gcloud iam service-accounts describe "${DASHBOARD_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud iam service-accounts create "${DASHBOARD_SA_NAME}" --project="${PROJECT_ID}"
fi

# 2. Build Dashboard Image (Cloud Build)
echo "Building Dashboard Container..."
if [ -d "${SOURCE_DIR}" ]; then
    gcloud builds submit "${SOURCE_DIR}" \
        --tag="${CONTAINER_IMAGE}" \
        --project="${PROJECT_ID}" \
        --service-account="projects/${PROJECT_ID}/serviceAccounts/${CLOUDBUILD_SA_EMAIL}" \
        --default-buckets-behavior=REGIONAL_USER_OWNED_BUCKET
else
    echo "WARNING: Source directory not found at ${SOURCE_DIR}. Skipping build."
fi

# 3. BigQuery Dataset for Logs
echo "Creating Pipeline Logs Dataset..."
if ! bq --project_id="${PROJECT_ID}" show "${PIPELINE_LOGS_DATASET}" >/dev/null 2>&1; then
    # 90 days expiration (7776000000 ms)
    bq --project_id="${PROJECT_ID}" mk --location="${REGION}" --default_table_expiration 7776000000 "${PIPELINE_LOGS_DATASET}"
fi

# 4. Cloud Logging Sink
echo "Configuring Log Sink..."
LOG_FILTER='(resource.type="cloud_run_job" OR resource.type="cloud_run_revision" OR resource.type="cloud_function")
AND (resource.labels.service_name=~"github-archive" OR resource.labels.job_name=~"github-archive")'

if ! gcloud logging sinks describe "${LOG_SINK_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud logging sinks create "${LOG_SINK_NAME}" \
        "bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${PIPELINE_LOGS_DATASET}" \
        --log-filter="${LOG_FILTER}" \
        --use-partitioned-tables \
        --project="${PROJECT_ID}"
else
    echo "Log sink ${LOG_SINK_NAME} already exists."
fi

# Grant Sink Identity access to BQ Dataset
SINK_IDENTITY=$(gcloud logging sinks describe "${LOG_SINK_NAME}" --project="${PROJECT_ID}" --format="value(writerIdentity)")

bq add-iam-policy-binding \
    --member="${SINK_IDENTITY}" \
    --role="roles/bigquery.dataEditor" \
    "${PROJECT_ID}:${PIPELINE_LOGS_DATASET}" >/dev/null

# 5. IAM Bindings (Dashboard SA)
echo "Applying IAM..."

# Project Level: Job User & Resource Viewer (for INFORMATION_SCHEMA)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${DASHBOARD_SA_EMAIL}" --role="roles/bigquery.jobUser" --quiet >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${DASHBOARD_SA_EMAIL}" --role="roles/bigquery.resourceViewer" --quiet >/dev/null

# Dataset Level: Pipeline Logs (Read)
bq add-iam-policy-binding \
    --member="serviceAccount:${DASHBOARD_SA_EMAIL}" \
    --role="roles/bigquery.dataViewer" \
    "${PROJECT_ID}:${PIPELINE_LOGS_DATASET}" >/dev/null

# Dataset Level: Github Archive (Read Phase 3 Data)
bq add-iam-policy-binding \
    --member="serviceAccount:${DASHBOARD_SA_EMAIL}" \
    --role="roles/bigquery.dataViewer" \
    "${PROJECT_ID}:github_archive" >/dev/null

# 6. Stale Binding Cleanup (Terraform Provisioner Logic)
cleanup_stale_bindings() {
  local dataset=$1
  echo "Checking for stale SA bindings in ${dataset} dataset..."
  # Look for "deleted:serviceAccount:..." pattern in IAM policy
  STALE=$(bq show --format=prettyjson "${PROJECT_ID}:${dataset}" 2>/dev/null | grep -o "\"deleted:serviceAccount:${DASHBOARD_SA_EMAIL}?uid=[0-9]*\"" | head -1 || true)
  
  if [ -n "$STALE" ]; then
    MEMBER=$(echo "$STALE" | tr -d '"')
    echo "Found stale binding: $MEMBER"
    echo "Removing..."
    bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql \
      "REVOKE \`roles/bigquery.dataViewer\` ON SCHEMA \`${PROJECT_ID}.${dataset}\` FROM \"$MEMBER\""
    echo "Stale SA binding removed."
  else
    echo "No stale SA bindings found."
  fi
}

cleanup_stale_bindings "github_archive"

# 7. IAM Verification with Retry
echo "Verifying IAM propagation..."
MAX_ATTEMPTS=6
for i in $(seq 1 $MAX_ATTEMPTS); do
    # Note: This check requires the caller to have Token Creator permissions on the Dashboard SA
    # If running as User, ensure you have permissions. If running as Deployer SA, it should have it.
    TOKEN=$(gcloud auth print-access-token --impersonate-service-account="${DASHBOARD_SA_EMAIL}" 2>/dev/null || true)
    
    if [ -n "$TOKEN" ]; then
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer $TOKEN" \
            "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/github_archive?fields=id")
        
        if [ "$STATUS" = "200" ]; then
            echo "IAM verified: Dashboard SA can access github_archive dataset."
            break
        else
            echo "  Access not yet propagated (HTTP $STATUS)... ($i/$MAX_ATTEMPTS)"
        fi
    else
        echo "  Could not impersonate SA (skipping verification)..."
        break
    fi
    
    if [ "$i" -eq "$MAX_ATTEMPTS" ]; then
        echo "WARNING: IAM verification timed out. Dashboard may need a few more minutes to work."
    fi
    sleep 10
done

# 8. Cloud Run Service
echo "Deploying Dashboard Service..."

# Cost Optimization (Learnings #1):
# --cpu-throttling ensures cpu_idle=true (billable only during request processing)

gcloud run deploy "${SERVICE_NAME}" \
    --image="${CONTAINER_IMAGE}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --service-account="${DASHBOARD_SA_EMAIL}" \
    --memory="512Mi" \
    --cpu="1" \
    --timeout="300s" \
    --min-instances=0 \
    --max-instances=1 \
    --cpu-throttling \
    --set-env-vars="PROJECT_ID=${PROJECT_ID},DATASET_ID=${PIPELINE_LOGS_DATASET}" \
    --allow-unauthenticated=true

URL=$(gcloud run services describe "${SERVICE_NAME}" --region="${REGION}" --format='value(status.url)')
echo "========================================================"
echo "Phase 4 Complete."
echo "Dashboard URL: ${URL}"
echo "========================================================"