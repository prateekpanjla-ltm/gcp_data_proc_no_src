#!/bin/bash
# =============================================================================
# Test Script for Phase 2 Cloud Run GitHub Archive Processor
# =============================================================================
set -e

# =============================================================================
# VARIABLES - Update these for your environment
# =============================================================================
PROJECT_ID="dev-dataprocessing-489305"
REGION="us-central1"
SERVICE_NAME="dev-github-archive-processor"
PROCESSOR_SA="dev-github-archive-processor@${PROJECT_ID}.iam.gserviceaccount.com"
LANDING_BUCKET="gh-archive-landing-${PROJECT_ID##*-}"

# =============================================================================
# COLORS
# =============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# TEST 1: Health Check
# =============================================================================
test_health_check() {
    log_info "=== Test 1: Health Check ==="

    local url=$(gcloud run services describe ${SERVICE_NAME} \
        --region=${REGION} \
        --project=${PROJECT_ID} \
        --format='value(status.url)')

    log_info "Service URL: ${url}"

    local response=$(curl -s -w "\n%{http_code}" "${url}/health")
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)

    if [ "$http_code" = "200" ]; then
        log_info "Health check passed!"
        echo "$body" | jq '.'
    else
        log_error "Health check failed with HTTP ${http_code}"
        echo "$body"
        return 1
    fi
}

# =============================================================================
# TEST 2: Readiness Check
# =============================================================================
test_readiness_check() {
    log_info "=== Test 2: Readiness Check ==="

    local url=$(gcloud run services describe ${SERVICE_NAME} \
        --region=${REGION} \
        --project=${PROJECT_ID} \
        --format='value(status.url)')

    local response=$(curl -s -w "\n%{http_code}" "${url}/ready")
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)

    if [ "$http_code" = "200" ]; then
        log_info "Readiness check passed!"
        echo "$body" | jq '.'
    else
        log_error "Readiness check failed with HTTP ${http_code}"
        echo "$body"
        return 1
    fi
}

# =============================================================================
# TEST 3: Direct HTTP Invocation (Manual /process endpoint)
# =============================================================================
test_direct_invocation() {
    log_info "=== Test 3: Direct HTTP Invocation ==="

    # First, find a test file in the landing bucket
    log_info "Looking for test file in gs://${LANDING_BUCKET}/github-archive/raw/ ..."

    local test_file=$(gsutil ls "gs://${LANDING_BUCKET}/github-archive/raw/*.json.gz" 2>/dev/null | head -n1)

    if [ -z "$test_file" ]; then
        log_warn "No test files found in landing bucket. Skipping direct invocation test."
        log_info "To test manually, upload a file first:"
        echo "  gsutil cp /path/to/test.json.gz gs://${LANDING_BUCKET}/github-archive/raw/"
        return 0
    fi

    log_info "Using test file: ${test_file}"

    local url=$(gcloud run services describe ${SERVICE_NAME} \
        --region=${REGION} \
        --project=${PROJECT_ID} \
        --format='value(status.url)')

    # Get an ID token for the service account
    log_info "Getting ID token for service account..."
    local token=$(gcloud auth print-identity-token \
        --audiences="${url}" \
        --impersonate-service-account=${PROCESSOR_SA})

    # Invoke the /process endpoint
    log_info "Invoking /process endpoint..."
    local response=$(curl -s -w "\n%{http_code}" \
        -X POST "${url}/process" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"file_path\": \"${test_file}\"}")

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)

    if [ "$http_code" = "200" ]; then
        log_info "Direct invocation passed!"
        echo "$body" | jq '.'
    else
        log_error "Direct invocation failed with HTTP ${http_code}"
        echo "$body"
        return 1
    fi
}

# =============================================================================
# TEST 4: Eventarc Trigger (Simulated GCS Event)
# =============================================================================
test_eventarc_trigger() {
    log_info "=== Test 4: Eventarc Trigger (via Pub/Sub) ==="

    # Find test file
    local test_file=$(gsutil ls "gs://${LANDING_BUCKET}/github-archive/raw/*.json.gz" 2>/dev/null | head -n1)

    if [ -z "$test_file" ]; then
        log_warn "No test files found. Cannot test Eventarc trigger."
        return 0
    fi

    # Extract just the filename (full path)
    local file_name="${test_file#gs://${LANDING_BUCKET}/}"

    log_info "Test file: ${file_name}"

    # Get the Eventarc trigger details
    local trigger_name="gh-archive-landing-${PROJECT_ID##*-}"
    local trigger_info=$(gcloud eventarc triggers describe ${trigger_name} \
        --region=${REGION} \
        --project=${PROJECT_ID} 2>/dev/null || echo "")

    if [ -z "$trigger_info" ]; then
        log_warn "Eventarc trigger '${trigger_name}' not found. Skipping Eventarc test."
        log_info "You may need to create the Eventarc trigger via Terraform first."
        return 0
    fi

    log_info "Eventarc trigger found: ${trigger_name}"

    # Get the Pub/Sub topic
    local topic=$(gcloud eventarc triggers describe ${trigger_name} \
        --region=${REGION} \
        --project=${PROJECT_ID} \
        --format='value.transport.pubsub.topic')

    if [ -z "$topic" ]; then
        log_error "Could not find Pub/Sub topic for Eventarc trigger"
        return 1
    fi

    log_info "Pub/Sub topic: ${topic}"

    # Create a Cloud Storage event payload
    local event_payload=$(cat <<EOF
{
  "bucket": "${LANDING_BUCKET}",
  "name": "${file_name}",
  "resourceState": "exists",
  "metageneration": "1"
}
EOF
)

    log_info "Publishing test event to Pub/Sub..."
    log_debug "Event payload: ${event_payload}"

    # Publish to Pub/Sub
    local pub_result=$(gcloud pubsub topics publish ${topic} \
        --project=${PROJECT_ID} \
        --message="${event_payload}" 2>&1)

    if [ $? -eq 0 ]; then
        log_info "Event published successfully!"
        log_info "Check Cloud Run logs to verify processing:"
        echo "  gcloud run logs tails ${SERVICE_NAME} --region=${REGION} --project=${PROJECT_ID} --limit=50"
    else
        log_error "Failed to publish event"
        echo "$pub_result"
        return 1
    fi
}

# =============================================================================
# TEST 5: Upload Test File and Trigger
# =============================================================================
test_upload_and_trigger() {
    log_info "=== Test 5: Upload Test File ==="

    # Check if we have a local test file
    local test_data_dir="../../tmp"
    local test_file="${test_data_dir}/sample_gharchive.json.gz"

    if [ ! -f "$test_file" ]; then
        log_warn "No test file found at ${test_file}"
        log_info "Skipping upload test."
        return 0
    fi

    # Upload with a timestamp to make it unique
    local timestamp=$(date +%s)
    local target_path="gs://${LANDING_BUCKET}/github-archive/raw/test-${timestamp}.json.gz"

    log_info "Uploading test file to ${target_path}..."
    gsutil cp "$test_file" "${target_path}"

    if [ $? -eq 0 ]; then
        log_info "Upload successful! Eventarc should trigger automatically."
        log_info "Check logs for processing:"
        echo "  gcloud run logs tails ${SERVICE_NAME} --region=${REGION} --project=${PROJECT_ID} --limit=50"
    else
        log_error "Upload failed"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log_info "Starting tests for Cloud Run service: ${SERVICE_NAME}"
    log_info "Project: ${PROJECT_ID}, Region: ${REGION}"
    echo

    # Parse arguments
    TEST_CASE="${1:-all}"

    case "$TEST_CASE" in
        health)
            test_health_check
            ;;
        ready)
            test_readiness_check
            ;;
        direct)
            test_direct_invocation
            ;;
        eventarc)
            test_eventarc_trigger
            ;;
        upload)
            test_upload_and_trigger
            ;;
        all)
            test_health_check
            echo
            test_readiness_check
            echo
            test_direct_invocation
            echo
            test_eventarc_trigger
            ;;
        *)
            log_error "Unknown test case: ${TEST_CASE}"
            echo "Usage: $0 [health|ready|direct|eventarc|upload|all]"
            exit 1
            ;;
    esac

    log_info "Tests completed!"
}

# Run main
main "$@"
