#!/bin/bash
# =============================================================================
# Phase 1: GitHub Archive Ingestion - gcloud equivalent
# Comprehensive script including build, IAM, and configuration resources.
# =============================================================================

set -e

# Configuration
PROJECT_ID="${PROJECT_ID:-dev-dataprocessing-489305}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REGION="${REGION:-us-central1}"

# Derived Resource Names
DOWNLOADER_SA_NAME="${ENVIRONMENT}-github-archive-downloader"
DOWNLOADER_SA_EMAIL="${DOWNLOADER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SCHEDULER_SA_NAME="${ENVIRONMENT}-scheduler"
SCHEDULER_SA_EMAIL="${SCHEDULER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CLOUDBUILD_SA_NAME="${ENVIRONMENT}-cloud-build"
CLOUDBUILD_SA_EMAIL="${CLOUDBUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

LANDING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing"
AR_REPO_NAME="${ENVIRONMENT}-github-archive"
JOB_NAME="${ENVIRONMENT}-github-archive-download-gsutil"
SCHEDULER_JOB_NAME="${ENVIRONMENT}-github-archive-download-job"
CONTAINER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO_NAME}/github-archive-downloader:latest"

# Path handling
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLOUDBUILD_CONFIG_FILE="${PROJECT_ROOT}/config/cloudbuild-phase1.yaml"
SOURCE_CODE_DIR="${PROJECT_ROOT}/src/github_archive"

echo "Creating Phase 1 infrastructure for project: ${PROJECT_ID}"

# 0. Pre-flight: Enable APIs
echo "Enabling required APIs..."
gcloud services enable \
    run.googleapis.com \
    cloudscheduler.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    iam.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}"

# 1. Artifact Registry
echo "Creating Artifact Registry repository..."
if ! gcloud artifacts repositories describe "${AR_REPO_NAME}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud artifacts repositories create "${AR_REPO_NAME}" \
        --repository-format=docker \
        --location="${REGION}" \
        --description="Docker repository for GitHub Archive pipeline" \
        --project="${PROJECT_ID}"
fi

# 2. Service Accounts
echo "Creating Service Accounts..."
for sa_name in "$DOWNLOADER_SA_NAME" "$SCHEDULER_SA_NAME" "$CLOUDBUILD_SA_NAME"; do
    sa_email="${sa_name}@${PROJECT_ID}.iam.gserviceaccount.com"
    if ! gcloud iam service-accounts describe "${sa_email}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
        gcloud iam service-accounts create "${sa_name}" --display-name="Service Account for ${sa_name}" --project="${PROJECT_ID}"
    fi
done

# 3. Comprehensive IAM Bindings
echo "Applying IAM..."
# Downloader SA permissions
gcloud storage buckets add-iam-policy-binding "gs://${LANDING_BUCKET}" \
    --member="serviceAccount:${DOWNLOADER_SA_EMAIL}" --role="roles/storage.objectUser" --quiet >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${DOWNLOADER_SA_EMAIL}" --role="roles/logging.logWriter" --quiet >/dev/null

# Add role for Downloader SA to pull its own image from Artifact Registry
gcloud artifacts repositories add-iam-policy-binding "${AR_REPO_NAME}" \
    --location="${REGION}" \
    --member="serviceAccount:${DOWNLOADER_SA_EMAIL}" \
    --role="roles/artifactregistry.reader" \
    --project="${PROJECT_ID}" --quiet >/dev/null

# Cloud Build SA permissions (as per cloudbuild_sa.tf)
CLOUDBUILD_ROLES=(
    "roles/cloudbuild.builds.builder"
    "roles/run.admin"
    "roles/cloudfunctions.developer"
    "roles/iam.serviceAccountUser"
    "roles/logging.logWriter"
)
for role in "${CLOUDBUILD_ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${CLOUDBUILD_SA_EMAIL}" \
        --role="$role" --quiet >/dev/null
done

# Cloud Scheduler Service Agent permission (as per service_accounts.tf)
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
SCHEDULER_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
gcloud iam service-accounts add-iam-policy-binding "${SCHEDULER_SA_EMAIL}" \
    --member="serviceAccount:${SCHEDULER_AGENT}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --project="${PROJECT_ID}" --quiet >/dev/null

# 4. IAM Propagation Wait Logic (from build.tf)
echo "Waiting for IAM propagation for Cloud Build SA..."
MAX_ATTEMPTS=12
for i in $(seq 1 $MAX_ATTEMPTS); do
    echo "Checking IAM propagation (attempt $i/$MAX_ATTEMPTS)..."
    # We test a core permission of the cloudbuild.builds.builder role
    if gcloud projects get-iam-policy "${PROJECT_ID}" \
        --flatten="bindings[].members" \
        --format='table(bindings.role)' \
        --filter="bindings.members:serviceAccount:${CLOUDBUILD_SA_EMAIL} AND bindings.role:roles/cloudbuild.builds.builder" | grep -q "roles/cloudbuild.builds.builder"; then
        echo "IAM permissions confirmed for Cloud Build SA."
        break
    fi
    if [ "$i" -eq "$MAX_ATTEMPTS" ]; then
        echo "ERROR: IAM propagation timed out after 120s"
        exit 1
    fi
    echo "  Not yet propagated, waiting 10s..."
    sleep 10
done

# 5. Automated Cloud Build
echo "Submitting Cloud Build job to build downloader image..."
gcloud builds submit "${SOURCE_CODE_DIR}" \
    --config="${CLOUDBUILD_CONFIG_FILE}" \
    --project="${PROJECT_ID}" \
    --substitutions="_REGION=${REGION},_ENV=${ENVIRONMENT}" \
    --service-account="${CLOUDBUILD_SA_EMAIL}"

# 6. GCS Bucket with Lifecycle Policy
echo "Creating Landing Bucket with lifecycle rule..."
if ! gcloud storage buckets describe "gs://${LANDING_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${LANDING_BUCKET}" --project="${PROJECT_ID}" --location="${REGION}" --uniform-bucket-level-access
fi

cat <<EOF > lifecycle.json
{ "rule": [{ "action": { "type": "Delete" }, "condition": { "age": 6 } }] }
EOF
gcloud storage buckets update "gs://${LANDING_BUCKET}" --lifecycle-file=lifecycle.json
rm lifecycle.json

# 7. Cloud Run Job
echo "Deploying Cloud Run Job..."
cat <<EOF > job_spec.yaml
apiVersion: run.googleapis.com/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  labels:
    cloud.googleapis.com/location: ${REGION}
  annotations:
    run.googleapis.com/launch-stage: BETA
spec:
  template:
    metadata:
      annotations:
        run.googleapis.com/execution-environment: gen2
    spec:
      taskCount: 1
      template:
        spec:
          serviceAccountName: ${DOWNLOADER_SA_EMAIL}
          timeoutSeconds: 1800
          containers:
          - image: ${CONTAINER_IMAGE}
            resources:
              limits:
                cpu: 1000m
                memory: 512Mi
            env:
            - name: BUCKET_NAME
              value: ${LANDING_BUCKET}
            - name: ENVIRONMENT
              value: ${ENVIRONMENT}
EOF

gcloud run jobs replace job_spec.yaml --project="${PROJECT_ID}" --region="${REGION}"
rm job_spec.yaml

# 8. Cloud Scheduler
echo "Deploying Cloud Scheduler..."
JOB_API_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${JOB_NAME}:run"

# Grant invoker permission to Scheduler SA
gcloud run jobs add-iam-policy-binding "${JOB_NAME}" \
    --location="${REGION}" \
    --member="serviceAccount:${SCHEDULER_SA_EMAIL}" \
    --role="roles/run.invoker" \
    --project="${PROJECT_ID}" --quiet >/dev/null

# Create/Update Scheduler
if gcloud scheduler jobs describe "${SCHEDULER_JOB_NAME}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud scheduler jobs update http "${SCHEDULER_JOB_NAME}" \
        --location="${REGION}" --schedule="30 * * * *" \
        --uri="${JOB_API_URI}" \
        --oauth-service-account-email="${SCHEDULER_SA_EMAIL}" \
        --project="${PROJECT_ID}" --time-zone="UTC" \
        --max-retry-attempts=2 --min-backoff-duration=10s
else
    gcloud scheduler jobs create http "${SCHEDULER_JOB_NAME}" \
        --location="${REGION}" --schedule="30 * * * *" \
        --uri="${JOB_API_URI}" \
        --oauth-service-account-email="${SCHEDULER_SA_EMAIL}" \
        --project="${PROJECT_ID}" --time-zone="UTC" \
        --max-retry-attempts=2 --min-backoff-duration=10s
fi