#!/bin/bash
# =============================================================================
# Phase 2: GitHub Archive Processing - gcloud equivalent
# Comprehensive script including APIs, Service Agents, and Build Triggers
# =============================================================================

set -e

# Configuration
PROJECT_ID="${PROJECT_ID:-dev-dataprocessing-489305}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REGION="${REGION:-us-central1}"

# Resources
PROCESSOR_SA_NAME="${ENVIRONMENT}-github-archive-processor"
PROCESSOR_SA_EMAIL="${PROCESSOR_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
INVOKER_SA_NAME="${ENVIRONMENT}-processor-eventarc-invoker"
INVOKER_SA_EMAIL="${INVOKER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SPLITTER_SA_NAME="${ENVIRONMENT}-file-splitter"
SPLITTER_SA_EMAIL="${SPLITTER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

LANDING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing"
STAGING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-staging"
SERVICE_NAME="${ENVIRONMENT}-github-archive-processor"
TRIGGER_NAME="${ENVIRONMENT}-github-archive-storage-trigger"
BUILD_TRIGGER_NAME="${ENVIRONMENT}-phase2-processor"
CONTAINER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ENVIRONMENT}-github-archive/processor:latest"

echo "Creating Phase 2 infrastructure..."

# 0. Enable APIs (Terraform enables 9 explicitly)
echo "Enabling required APIs..."
gcloud services enable \
    eventarc.googleapis.com \
    eventarcpublishing.googleapis.com \
    run.googleapis.com \
    storage.googleapis.com \
    cloudresourcemanager.googleapis.com \
    iam.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    cloudbuild.googleapis.com \
    --project="${PROJECT_ID}"

# 1. Service Agent Initialization
# Terraform runs `gcloud beta services identity create` for these
echo "Initializing Service Agents..."

# Eventarc Service Agent
gcloud beta services identity create --service=eventarc.googleapis.com --project="${PROJECT_ID}" 2>/dev/null || true

# GCS Service Agent
gcloud storage service-agent --project="${PROJECT_ID}" 2>/dev/null || true

# 2. Service Accounts (Processor, Invoker, Splitter)
echo "Creating Service Accounts..."
for sa in "$PROCESSOR_SA_NAME" "$INVOKER_SA_NAME" "$SPLITTER_SA_NAME"; do
    if ! gcloud iam service-accounts describe "${sa}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}" >/dev/null 2>&1; then
        gcloud iam service-accounts create "${sa}" --project="${PROJECT_ID}"
    fi
done

# 3. Staging Bucket
echo "Creating Staging Bucket..."
if ! gcloud storage buckets describe "gs://${STAGING_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${STAGING_BUCKET}" --project="${PROJECT_ID}" --location="${REGION}" --uniform-bucket-level-access
fi
# Apply lifecycle rule (30-day auto-delete per Terraform)
cat <<EOF > lifecycle_staging.json
{ "rule": [{ "action": { "type": "Delete" }, "condition": { "age": 30 } }] }
EOF
gcloud storage buckets update "gs://${STAGING_BUCKET}" --lifecycle-file=lifecycle_staging.json
rm lifecycle_staging.json

# 4. IAM Bindings
echo "Applying IAM..."

# Processor SA Permissions
# Processor needs to read Landing (Least Privilege: objectViewer)
gcloud storage buckets add-iam-policy-binding "gs://${LANDING_BUCKET}" \
    --member="serviceAccount:${PROCESSOR_SA_EMAIL}" --role="roles/storage.objectViewer" --quiet >/dev/null
# Processor needs to write Staging (Split: objectCreator + objectViewer)
gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="serviceAccount:${PROCESSOR_SA_EMAIL}" --role="roles/storage.objectCreator" --quiet >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="serviceAccount:${PROCESSOR_SA_EMAIL}" --role="roles/storage.objectViewer" --quiet >/dev/null

# Logging & Monitoring (added metricWriter)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PROCESSOR_SA_EMAIL}" --role="roles/logging.logWriter" --quiet >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PROCESSOR_SA_EMAIL}" --role="roles/monitoring.metricWriter" --quiet >/dev/null

# Splitter SA Permissions (Logging & Monitoring)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SPLITTER_SA_EMAIL}" --role="roles/logging.logWriter" --quiet >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SPLITTER_SA_EMAIL}" --role="roles/monitoring.metricWriter" --quiet >/dev/null

# Splitter SA Bucket Permissions (Read/Write Landing)
gcloud storage buckets add-iam-policy-binding "gs://${LANDING_BUCKET}" \
    --member="serviceAccount:${SPLITTER_SA_EMAIL}" --role="roles/storage.objectViewer" --quiet >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${LANDING_BUCKET}" \
    --member="serviceAccount:${SPLITTER_SA_EMAIL}" --role="roles/storage.objectCreator" --quiet >/dev/null

# Invoker SA Permissions (Logging)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${INVOKER_SA_EMAIL}" --role="roles/logging.logWriter" --quiet >/dev/null

# Service Agent Bindings (GCS Publisher & Eventarc Receiver)
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
GCS_SERVICE_AGENT="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"
EVENTARC_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"

# GCS Service Agent needs Pub/Sub Publisher to send events to Eventarc
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GCS_SERVICE_AGENT}" --role="roles/pubsub.publisher" --quiet >/dev/null

# Eventarc Service Agent needs Event Receiver
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${EVENTARC_SERVICE_AGENT}" --role="roles/eventarc.eventReceiver" --quiet >/dev/null

# 5. Cloud Build Trigger
echo "Creating Cloud Build Trigger..."
# Using inline config to match Terraform's inline build block
cat <<EOF > cloudbuild-phase2.yaml
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', '${REGION}-docker.pkg.dev/${PROJECT_ID}/${ENVIRONMENT}-github-archive/processor:\$SHORT_SHA', '-t', '${REGION}-docker.pkg.dev/${PROJECT_ID}/${ENVIRONMENT}-github-archive/processor:latest', '-f', 'Dockerfile.processor', '.']
- name: 'gcr.io/cloud-builders/docker'
  args: ['push', '--all-tags', '${REGION}-docker.pkg.dev/${PROJECT_ID}/${ENVIRONMENT}-github-archive/processor']
- name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    gcloud run deploy ${SERVICE_NAME} \
      --image ${REGION}-docker.pkg.dev/${PROJECT_ID}/${ENVIRONMENT}-github-archive/processor:\$SHORT_SHA \\
      --region ${REGION} \
      --service-account ${PROCESSOR_SA_EMAIL} \
      --memory 4Gi \
      --cpu 2 \
      --timeout 3600s \
      --max-instances 5 \
      --concurrency 3 \
      --set-env-vars PROJECT_ID=${PROJECT_ID},LANDING_BUCKET=${LANDING_BUCKET},STAGING_BUCKET=${STAGING_BUCKET},FILE_SIZE_THRESHOLD_MB=50,CHUNKSIZE=100000
EOF

if ! gcloud builds triggers describe "${BUILD_TRIGGER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud builds triggers create manual \
        --name="${BUILD_TRIGGER_NAME}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --inline-config=cloudbuild-phase2.yaml \
        --description="Build and deploy Phase 2 GitHub Archive processor"
fi
rm cloudbuild-phase2.yaml

# 6. Cloud Run Service
echo "Deploying Cloud Run Service..."
# Using cpu-throttling (cpu-idle) to save costs per Learnings #1
# Added: Labels, Health Check (/health)
gcloud run deploy "${SERVICE_NAME}" \
    --image="${CONTAINER_IMAGE}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --service-account="${PROCESSOR_SA_EMAIL}" \
    --memory="4Gi" \
    --cpu="2" \
    --timeout="3600s" \
    --min-instances=0 \
    --max-instances=5 \
    --concurrency=3 \
    --ingress=all \
    --no-cpu-throttling=false \
    --labels="environment=${ENVIRONMENT},phase=processing,managed_by=gcloud_script" \
    --startup-probe-http-get-path="/health" \
    --startup-probe-period="240s" \
    --set-env-vars="PROJECT_ID=${PROJECT_ID},LANDING_BUCKET=${LANDING_BUCKET},STAGING_BUCKET=${STAGING_BUCKET},FILE_SIZE_THRESHOLD_MB=50,CHUNKSIZE=100000" \
    --allow-unauthenticated=false

# 7. Eventarc Trigger
echo "Deploying Eventarc Trigger..."

# Grant Invoker SA permissions
gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
    --member="serviceAccount:${INVOKER_SA_EMAIL}" \
    --role="roles/run.invoker" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${INVOKER_SA_EMAIL}" \
    --role="roles/eventarc.eventReceiver" --quiet >/dev/null

# Grant Token Creator to Pub/Sub Service Agent (Learnings #7)
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

gcloud iam service-accounts add-iam-policy-binding "${INVOKER_SA_EMAIL}" \
    --member="serviceAccount:${PUBSUB_SA}" \
    --role="roles/iam.serviceAccountTokenCreator" --quiet >/dev/null

# Create Trigger
if ! gcloud eventarc triggers describe "${TRIGGER_NAME}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud eventarc triggers create "${TRIGGER_NAME}" \
        --location="${REGION}" \
        --destination-run-service="${SERVICE_NAME}" \
        --destination-run-region="${REGION}" \
        --event-filters="type=google.cloud.storage.object.v1.finalized" \
        --event-filters="bucket=${LANDING_BUCKET}" \
        --service-account="${INVOKER_SA_EMAIL}" \
        --project="${PROJECT_ID}"
else
    echo "Trigger ${TRIGGER_NAME} already exists."
fi

# 6. Fix Pub/Sub Ack Deadline (Learnings #16)
echo "Updating Pub/Sub Ack Deadline..."
# Get topic from trigger
TOPIC=$(gcloud eventarc triggers describe "${TRIGGER_NAME}" --location="${REGION}" --format='value(transport.pubsub.topic)')
# Subscription is usually created with a random name, but linked to the topic.
# Finding the subscription for that topic:
SUBSCRIPTION=$(gcloud pubsub subscriptions list --filter="topic:${TOPIC}" --format="value(name)" | head -n 1)
if [ -n "$SUBSCRIPTION" ]; then
    gcloud pubsub subscriptions update "$SUBSCRIPTION" --ack-deadline=600
fi