#!/bin/bash
# =============================================================================
# Phase 3: BigQuery Loading - gcloud equivalent
# =============================================================================

set -e

# Configuration
PROJECT_ID="${PROJECT_ID:-dev-dataprocessing-489305}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REGION="${REGION:-us-central1}"

# Derived Names
LOADER_SA_NAME="${ENVIRONMENT}-github-archive-bq-loader"
LOADER_SA_EMAIL="${LOADER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
INVOKER_SA_NAME="${ENVIRONMENT}-phase3-eventarc-invoker"
INVOKER_SA_EMAIL="${INVOKER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CLOUDBUILD_SA_NAME="${ENVIRONMENT}-cloud-build"
CLOUDBUILD_SA_EMAIL="${CLOUDBUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

STAGING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-staging"
SOURCE_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-gcf-source"
DATASET_ID="github_archive"
TABLE_ID="github_events"
FUNCTION_NAME="${ENVIRONMENT}-bq-loader"

# Path handling (assuming script runs from infrastructure/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/github_archive/phase3_loadbigquery"
SCHEMA_FILE="$(dirname "$(dirname "$SCRIPT_DIR")")/infrastructure/github_archive/phase3_loadbigquery/terraform/layers/01_static/schema.json"

echo "Creating Phase 3 infrastructure..."

# 0. Enable APIs
echo "Enabling required APIs..."
gcloud services enable \
    bigquery.googleapis.com \
    cloudfunctions.googleapis.com \
    run.googleapis.com \
    eventarc.googleapis.com \
    bigquerydatatransfer.googleapis.com \
    --project="${PROJECT_ID}"

# 1. Service Accounts
echo "Creating Service Accounts..."
for sa in "$LOADER_SA_NAME" "$INVOKER_SA_NAME"; do
    if ! gcloud iam service-accounts describe "${sa}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}" >/dev/null 2>&1; then
        gcloud iam service-accounts create "${sa}" --project="${PROJECT_ID}"
    fi
done

# 1b. Create Cloud Function Source Bucket
echo "Creating Source Bucket..."
if ! gcloud storage buckets describe "gs://${SOURCE_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${SOURCE_BUCKET}" --project="${PROJECT_ID}" --location="${REGION}" --uniform-bucket-level-access
fi

# 2. BigQuery Resources
echo "Creating BigQuery Resources..."
if ! bq --project_id="${PROJECT_ID}" show "${DATASET_ID}" >/dev/null 2>&1; then
    bq --project_id="${PROJECT_ID}" mk --location="${REGION}" "${DATASET_ID}"
fi

if ! bq --project_id="${PROJECT_ID}" show "${DATASET_ID}.${TABLE_ID}" >/dev/null 2>&1; then
    if [ -f "$SCHEMA_FILE" ]; then
        echo "Creating table with schema from $SCHEMA_FILE..."
        bq --project_id="${PROJECT_ID}" mk --table --time_partitioning_type=DAY --time_partitioning_expiration=31622400 --clustering_fields=event_type "${DATASET_ID}.${TABLE_ID}" "$SCHEMA_FILE"
    else
        echo "WARNING: Schema file not found at $SCHEMA_FILE. Creating empty table (may cause pipeline errors)."
        bq --project_id="${PROJECT_ID}" mk --table --time_partitioning_type=DAY --time_partitioning_expiration=31622400 --clustering_fields=event_type "${DATASET_ID}.${TABLE_ID}"
    fi
fi

# 3. IAM Bindings
echo "Applying IAM..."

# Loader SA needs access to Staging Bucket and BigQuery
gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="serviceAccount:${LOADER_SA_EMAIL}" --role="roles/storage.objectAdmin" --quiet >/dev/null

# Project Level Permissions
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${LOADER_SA_EMAIL}" --role="roles/bigquery.dataEditor" --quiet >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${LOADER_SA_EMAIL}" --role="roles/bigquery.jobUser" --quiet >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${LOADER_SA_EMAIL}" --role="roles/logging.logWriter" --quiet >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${LOADER_SA_EMAIL}" --role="roles/monitoring.metricWriter" --quiet >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${LOADER_SA_EMAIL}" --role="roles/artifactregistry.reader" --quiet >/dev/null

# Scheduled Query requires BigQuery Admin on the SA (per Terraform)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${LOADER_SA_EMAIL}" --role="roles/bigquery.admin" --quiet >/dev/null

# Dataset Level Permissions (Data Editor)
bq add-iam-policy-binding \
    --member="serviceAccount:${LOADER_SA_EMAIL}" \
    --role="roles/bigquery.dataEditor" \
    "${PROJECT_ID}:${DATASET_ID}" >/dev/null

# Invoker SA needs to receive events and invoke the function
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${INVOKER_SA_EMAIL}" --role="roles/eventarc.eventReceiver" --quiet >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${INVOKER_SA_EMAIL}" --role="roles/logging.logWriter" --quiet >/dev/null

# Eventarc Service Agent needs objectViewer on Staging Bucket (to validate trigger bucket existence)
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
EVENTARC_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"
GCS_SERVICE_AGENT="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"

# GCS Service Agent needs Pub/Sub Publisher (for GCS triggers underlying Eventarc)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GCS_SERVICE_AGENT}" --role="roles/pubsub.publisher" --quiet >/dev/null

gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="serviceAccount:${EVENTARC_SERVICE_AGENT}" \
    --role="roles/storage.objectViewer" --quiet >/dev/null

# Cloud Build SA needs actAs on Loader SA (for deployment)
gcloud iam service-accounts add-iam-policy-binding "${LOADER_SA_EMAIL}" \
    --member="serviceAccount:${CLOUDBUILD_SA_EMAIL}" \
    --role="roles/iam.serviceAccountUser" \
    --project="${PROJECT_ID}" --quiet >/dev/null

# 4. Deploy Cloud Function (2nd Gen)
echo "Deploying Cloud Function (2nd Gen)..."

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Source directory not found at $SOURCE_DIR"
    exit 1
fi

# Note: This command creates the Function, the underlying Cloud Run service, AND the Eventarc trigger.
# We use --trigger-service-account to specify the separate invoker identity.
gcloud functions deploy "${FUNCTION_NAME}" \
    --gen2 \
    --region="${REGION}" \
    --runtime="python311" \
    --source="${SOURCE_DIR}" \
    --entry-point="load_to_bigquery" \
    --memory="256Mi" \
    --timeout="120s" \
    --max-instances=10 \
    --ingress-settings="internal-only" \
    --retry \
    --service-account="${LOADER_SA_EMAIL}" \
    --stage-bucket="${SOURCE_BUCKET}" \
    --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" \
    --trigger-event-filters="bucket=${STAGING_BUCKET}" \
    --trigger-service-account="${INVOKER_SA_EMAIL}" \
    --trigger-location="${REGION}" \
    --set-env-vars="PROJECT_ID=${PROJECT_ID},DATASET_ID=${DATASET_ID},TABLE_ID=${TABLE_ID},DELETE_AFTER_LOAD=false" \
    --project="${PROJECT_ID}"

# 5. ELT Layer (Views & Scheduled Queries)
echo "Deploying ELT Layer..."

# 5a. Staging View (Deduplication)
echo "Creating View: stg_events"
bq mk --use_legacy_sql=false --view \
"SELECT event_id, event_type, created_at, actor_login, actor_id, repo_name, repo_id, payload_ref, payload_size, payload_distinct_size, payload_issue_labels, etl_create_ts FROM \`${PROJECT_ID}.${DATASET_ID}.${TABLE_ID}\` WHERE event_id IS NOT NULL QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY etl_create_ts DESC) = 1" \
"${PROJECT_ID}:${DATASET_ID}.stg_events" 2>/dev/null || bq update --use_legacy_sql=false --view \
"SELECT event_id, event_type, created_at, actor_login, actor_id, repo_name, repo_id, payload_ref, payload_size, payload_distinct_size, payload_issue_labels, etl_create_ts FROM \`${PROJECT_ID}.${DATASET_ID}.${TABLE_ID}\` WHERE event_id IS NOT NULL QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY etl_create_ts DESC) = 1" \
"${PROJECT_ID}:${DATASET_ID}.stg_events"

# 5b. Mart Views
echo "Creating View: developer_daily_activity"
bq mk --use_legacy_sql=false --view \
"SELECT DATE(created_at) AS day, actor_login, actor_id, COUNT(*) AS total_events, COUNTIF(event_type = 'PushEvent') AS pushes, COUNTIF(event_type = 'IssuesEvent') AS issues_opened, COUNTIF(event_type = 'PullRequestEvent') AS prs_opened, COUNTIF(event_type = 'IssueCommentEvent') AS comments, SUM(IFNULL(payload_distinct_size, 0)) AS distinct_commits, COUNT(DISTINCT repo_name) AS repos_touched, MIN(created_at) AS first_event, MAX(created_at) AS last_event, TIMESTAMP_DIFF(MAX(created_at), MIN(created_at), MINUTE) AS active_minutes FROM \`${PROJECT_ID}.${DATASET_ID}.stg_events\` GROUP BY day, actor_login, actor_id" \
"${PROJECT_ID}:${DATASET_ID}.developer_daily_activity" 2>/dev/null || bq update --use_legacy_sql=false --view \
"SELECT DATE(created_at) AS day, actor_login, actor_id, COUNT(*) AS total_events, COUNTIF(event_type = 'PushEvent') AS pushes, COUNTIF(event_type = 'IssuesEvent') AS issues_opened, COUNTIF(event_type = 'PullRequestEvent') AS prs_opened, COUNTIF(event_type = 'IssueCommentEvent') AS comments, SUM(IFNULL(payload_distinct_size, 0)) AS distinct_commits, COUNT(DISTINCT repo_name) AS repos_touched, MIN(created_at) AS first_event, MAX(created_at) AS last_event, TIMESTAMP_DIFF(MAX(created_at), MIN(created_at), MINUTE) AS active_minutes FROM \`${PROJECT_ID}.${DATASET_ID}.stg_events\` GROUP BY day, actor_login, actor_id" \
"${PROJECT_ID}:${DATASET_ID}.developer_daily_activity"

echo "Creating View: bot_vs_human_activity"
bq mk --use_legacy_sql=false --view \
"SELECT DATE(created_at) AS day, CASE WHEN actor_login LIKE '%[bot]' THEN 'bot' WHEN actor_login LIKE '%-bot' THEN 'bot' WHEN actor_login LIKE '%Bot' THEN 'bot' WHEN actor_login IN ('dependabot', 'renovate', 'github-actions') THEN 'bot' ELSE 'human' END AS actor_type, COUNT(*) AS event_count, COUNT(DISTINCT actor_login) AS unique_actors, COUNT(DISTINCT repo_name) AS unique_repos, COUNTIF(event_type = 'PushEvent') AS pushes, COUNTIF(event_type = 'PullRequestEvent') AS prs FROM \`${PROJECT_ID}.${DATASET_ID}.stg_events\` GROUP BY day, actor_type" \
"${PROJECT_ID}:${DATASET_ID}.bot_vs_human_activity" 2>/dev/null || bq update --use_legacy_sql=false --view \
"SELECT DATE(created_at) AS day, CASE WHEN actor_login LIKE '%[bot]' THEN 'bot' WHEN actor_login LIKE '%-bot' THEN 'bot' WHEN actor_login LIKE '%Bot' THEN 'bot' WHEN actor_login IN ('dependabot', 'renovate', 'github-actions') THEN 'bot' ELSE 'human' END AS actor_type, COUNT(*) AS event_count, COUNT(DISTINCT actor_login) AS unique_actors, COUNT(DISTINCT repo_name) AS unique_repos, COUNTIF(event_type = 'PushEvent') AS pushes, COUNTIF(event_type = 'PullRequestEvent') AS prs FROM \`${PROJECT_ID}.${DATASET_ID}.stg_events\` GROUP BY day, actor_type" \
"${PROJECT_ID}:${DATASET_ID}.bot_vs_human_activity"

# 5c. Materialized View (Auto-refresh)
echo "Creating Materialized View: mv_repo_daily_stats"
# Note: update is not supported for materialized views in the same way, usually requires drop/create if options change
if ! bq --project_id="${PROJECT_ID}" show "${DATASET_ID}.mv_repo_daily_stats" >/dev/null 2>&1; then
    bq mk --use_legacy_sql=false --materialized_view \
    --enable_refresh=true --refresh_interval_ms=1800000 \
    --expiration 0 \
    --description "Materialized view: daily repo activity stats (auto-refreshed)" \
    "${PROJECT_ID}:${DATASET_ID}.mv_repo_daily_stats" \
    "SELECT DATE(created_at) AS day, repo_name, COUNT(*) AS total_events, COUNTIF(event_type = 'PushEvent') AS pushes, COUNTIF(event_type = 'IssuesEvent') AS issues, COUNTIF(event_type = 'PullRequestEvent') AS pull_requests, COUNTIF(event_type = 'WatchEvent') AS stars, COUNTIF(event_type = 'ForkEvent') AS forks, APPROX_COUNT_DISTINCT(actor_login) AS unique_contributors FROM \`${PROJECT_ID}.${DATASET_ID}.${TABLE_ID}\` GROUP BY day, repo_name"
else
    echo "Materialized view mv_repo_daily_stats already exists."
fi

# 5d. Scheduled Query (Hourly Activity)
echo "Configuring Scheduled Query: hourly_activity_summary"
TRANSFER_DISPLAY_NAME="${ENVIRONMENT}-hourly-activity-summary"

# Check if transfer config exists
EXISTING_TRANSFER=$(bq ls --transfer_config --transfer_location="${REGION}" --project_id="${PROJECT_ID}" --format=json | grep "${TRANSFER_DISPLAY_NAME}")

if [ -z "$EXISTING_TRANSFER" ]; then
    # Construct a basic summary query for the schedule
    SCHEDULED_QUERY="INSERT INTO \`${PROJECT_ID}.${DATASET_ID}.hourly_activity_summary\` (hour, total_events, distinct_actors, distinct_repos) SELECT TIMESTAMP_TRUNC(created_at, HOUR) as hour, COUNT(*) as total_events, COUNT(DISTINCT actor_id) as distinct_actors, COUNT(DISTINCT repo_id) as distinct_repos FROM \`${PROJECT_ID}.${DATASET_ID}.${TABLE_ID}\` WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) GROUP BY 1"
    
    bq mk --transfer_config \
        --project_id="${PROJECT_ID}" \
        --location="${REGION}" \
        --data_source="scheduled_query" \
        --display_name="${TRANSFER_DISPLAY_NAME}" \
        --schedule="every 1 hours" \
        --service_account_name="${LOADER_SA_EMAIL}" \
        --params="{\"query\":\"${SCHEDULED_QUERY}\",\"destination_table_name_template\":\"hourly_activity_summary\",\"write_disposition\":\"WRITE_APPEND\"}"
else
    echo "Scheduled query ${TRANSFER_DISPLAY_NAME} already exists."
fi

# 6. Post-Deployment IAM Fixes (Learnings #7 & #18)
echo "Configuring Trigger IAM..."

# Grant Token Creator to Pub/Sub Service Agent on the Invoker SA
# This allows Pub/Sub to create an OIDC token identifying as the Invoker SA
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

gcloud iam service-accounts add-iam-policy-binding "${INVOKER_SA_EMAIL}" \
    --member="serviceAccount:${PUBSUB_SA}" \
    --role="roles/iam.serviceAccountTokenCreator" --quiet >/dev/null

# Grant Invoker SA permission to invoke the underlying Cloud Run service
# Note: Cloud Functions 2nd Gen creates a Cloud Run service with the same name
gcloud run services add-iam-policy-binding "${FUNCTION_NAME}" \
    --location="${REGION}" \
    --member="serviceAccount:${INVOKER_SA_EMAIL}" \
    --role="roles/run.invoker" \
    --project="${PROJECT_ID}" --quiet >/dev/null

# 6. Update Ack Deadline (Learnings #16)
echo "Updating Pub/Sub Ack Deadline..."
# The trigger name is auto-generated by gcloud functions deploy, usually based on function name
# We search for the trigger associated with this function
TRIGGER_ID=$(gcloud eventarc triggers list --location="${REGION}" --filter="destination_run_service:${FUNCTION_NAME}" --format="value(name)" | head -n 1)

if [ -n "$TRIGGER_ID" ]; then
    # Trigger ID format: projects/.../triggers/NAME
    TRIGGER_NAME_ONLY=$(basename "$TRIGGER_ID")
    TOPIC=$(gcloud eventarc triggers describe "$TRIGGER_NAME_ONLY" --location="${REGION}" --format='value(transport.pubsub.topic)')
    
    if [ -n "$TOPIC" ]; then
        # Find subscription for topic
        SUBSCRIPTION=$(gcloud pubsub subscriptions list --filter="topic:${TOPIC}" --format="value(name)" | head -n 1)
        if [ -n "$SUBSCRIPTION" ]; then
            echo "Setting ack deadline to 600s for $SUBSCRIPTION"
            gcloud pubsub subscriptions update "$SUBSCRIPTION" --ack-deadline=600
        fi
    fi
else
    echo "WARNING: Could not locate Eventarc trigger for function ${FUNCTION_NAME}"
fi

echo "Phase 3 deployment complete."