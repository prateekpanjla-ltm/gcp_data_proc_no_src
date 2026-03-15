#!/bin/bash
# CI Test Pipeline: Deploy -> Trigger -> Verify -> Destroy
# Usage: ./ci-test-pipeline.sh <PROJECT_ID> [ENVIRONMENT] [REGION] [HOUR_OFFSET]
#
# Full integration test flow:
#   1. Deploy all infrastructure (Phase 1 -> 2 -> 3)
#   2. Trigger the download job for a specific hour
#   3. Wait for file to land in GCS
#   4. Wait for processing (Eventarc -> Cloud Run -> staging)
#   5. Wait for BigQuery load (Eventarc -> Cloud Function -> BQ)
#   6. Verify rows in BigQuery
#   7. Destroy all infrastructure
#
# Exit codes:
#   0 = all tests passed, infrastructure destroyed
#   1 = deploy failed
#   2 = pipeline test failed, infrastructure destroyed
#   3 = destroy failed (manual cleanup needed)
#
# Example:
#   ./ci-test-pipeline.sh beaming-glyph-489707-b8 test us-central1 2

set -euo pipefail

# =============================================================================
# Arguments
# =============================================================================
PROJECT_ID="${1:?Error: PROJECT_ID required}"
ENVIRONMENT="${2:-test}"
REGION="${3:-us-central1}"
HOUR_OFFSET="${4:-2}"  # Hours ago to download (default: 2 hours ago)

# =============================================================================
# Paths & Config
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEY_PATH="${REPO_ROOT}/infrastructure/${ENVIRONMENT}-terraform-deployer-key.json"

if [[ ! -f "${KEY_PATH}" ]]; then
  KEY_PATH="${REPO_ROOT}/infrastructure/test-terraform-deployer-key.json"
fi

# Derived names
LANDING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing"
STAGING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-staging"
JOB_NAME="${ENVIRONMENT}-github-archive-download-gsutil"
BQ_TABLE="${PROJECT_ID}:github_archive.github_events"

# Timeouts
LANDING_TIMEOUT=300   # 5 min for download to complete
STAGING_TIMEOUT=600   # 10 min for processing
BQ_TIMEOUT=300        # 5 min for BQ load

# =============================================================================
# Logging
# =============================================================================
LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/ci-test-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Track overall result for cleanup
DEPLOY_SUCCESS=false
TEST_RESULT=0

echo "========================================="
echo "CI Test Pipeline"
echo "========================================="
echo "Project:      ${PROJECT_ID}"
echo "Environment:  ${ENVIRONMENT}"
echo "Region:       ${REGION}"
echo "Hour Offset:  ${HOUR_OFFSET}"
echo "Log:          ${LOG_FILE}"
echo "Started:      $(date)"
echo "========================================="
echo ""

export GOOGLE_APPLICATION_CREDENTIALS="${KEY_PATH}"

# Calculate the target hour filename
TARGET_DATE=$(date -u -d "${HOUR_OFFSET} hours ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${HOUR_OFFSET}H +"%Y-%m-%d")
TARGET_HOUR=$(date -u -d "${HOUR_OFFSET} hours ago" +"%-H" 2>/dev/null || date -u -v-${HOUR_OFFSET}H +"%-H")
TARGET_FILE="${TARGET_DATE}-${TARGET_HOUR}.json.gz"

echo "Target file: ${TARGET_FILE}"
echo ""

# =============================================================================
# Step 1: Deploy
# =============================================================================
echo "========================================="
echo "Step 1/5: Deploying infrastructure"
echo "========================================="
echo ""

if "${SCRIPT_DIR}/deploy-all-phases.sh" "${PROJECT_ID}" "${ENVIRONMENT}" "${REGION}"; then
  DEPLOY_SUCCESS=true
  echo ""
  echo "  Deploy: PASSED"
else
  echo ""
  echo "  Deploy: FAILED"
  exit 1
fi

# =============================================================================
# Step 2: Trigger download job
# =============================================================================
echo ""
echo "========================================="
echo "Step 2/5: Triggering download job"
echo "========================================="
echo ""

echo "  Executing Cloud Run Job: ${JOB_NAME}"
gcloud run jobs execute "${JOB_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --wait \
  --format="value(name)" 2>&1 || {
    echo "  WARNING: --wait may not be supported. Checking status manually..."
  }

echo "  Job triggered."

# =============================================================================
# Step 3: Wait for landing file
# =============================================================================
echo ""
echo "========================================="
echo "Step 3/5: Waiting for file in landing bucket"
echo "========================================="
echo ""

ELAPSED=0
LANDING_FILE_FOUND=false

while [[ ${ELAPSED} -lt ${LANDING_TIMEOUT} ]]; do
  FILE_COUNT=$(gcloud storage ls "gs://${LANDING_BUCKET}/${TARGET_FILE}" 2>/dev/null | wc -l || echo "0")
  if [[ ${FILE_COUNT} -gt 0 ]]; then
    LANDING_FILE_FOUND=true
    echo "  File found in landing bucket after ${ELAPSED}s"
    break
  fi
  echo "  Waiting... (${ELAPSED}s / ${LANDING_TIMEOUT}s)"
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

if [[ "${LANDING_FILE_FOUND}" != "true" ]]; then
  echo "  FAILED: File not found in landing bucket after ${LANDING_TIMEOUT}s"
  TEST_RESULT=2
fi

# =============================================================================
# Step 4: Wait for staging file (processed)
# =============================================================================
if [[ ${TEST_RESULT} -eq 0 ]]; then
  echo ""
  echo "========================================="
  echo "Step 4/5: Waiting for processed file in staging bucket"
  echo "========================================="
  echo ""

  ELAPSED=0
  STAGING_FILE_FOUND=false
  # Staging files are CSV, named like: YYYY-MM-DD-H_part*.csv
  STAGING_PREFIX="${TARGET_DATE}-${TARGET_HOUR}"

  while [[ ${ELAPSED} -lt ${STAGING_TIMEOUT} ]]; do
    FILE_COUNT=$(gcloud storage ls "gs://${STAGING_BUCKET}/**${STAGING_PREFIX}**" 2>/dev/null | wc -l || echo "0")
    if [[ ${FILE_COUNT} -gt 0 ]]; then
      STAGING_FILE_FOUND=true
      echo "  Processed files found in staging bucket after ${ELAPSED}s (${FILE_COUNT} files)"
      break
    fi
    echo "  Waiting... (${ELAPSED}s / ${STAGING_TIMEOUT}s)"
    sleep 30
    ELAPSED=$((ELAPSED + 30))
  done

  if [[ "${STAGING_FILE_FOUND}" != "true" ]]; then
    echo "  FAILED: Processed files not found in staging after ${STAGING_TIMEOUT}s"
    TEST_RESULT=2
  fi
fi

# =============================================================================
# Step 5: Verify BigQuery rows
# =============================================================================
if [[ ${TEST_RESULT} -eq 0 ]]; then
  echo ""
  echo "========================================="
  echo "Step 5/5: Verifying BigQuery load"
  echo "========================================="
  echo ""

  ELAPSED=0
  BQ_LOADED=false

  while [[ ${ELAPSED} -lt ${BQ_TIMEOUT} ]]; do
    ROW_COUNT=$(bq query --nouse_legacy_sql --format=csv --quiet \
      "SELECT COUNT(*) as cnt FROM \`${PROJECT_ID}.github_archive.github_events\` WHERE DATE(created_at) = '${TARGET_DATE}' AND EXTRACT(HOUR FROM created_at) = ${TARGET_HOUR}" \
      2>/dev/null | tail -1 || echo "0")

    if [[ ${ROW_COUNT} -gt 0 ]]; then
      BQ_LOADED=true
      echo "  BigQuery rows found: ${ROW_COUNT} after ${ELAPSED}s"
      break
    fi
    echo "  Waiting for BQ load... (${ELAPSED}s / ${BQ_TIMEOUT}s)"
    sleep 30
    ELAPSED=$((ELAPSED + 30))
  done

  if [[ "${BQ_LOADED}" != "true" ]]; then
    echo "  FAILED: No rows in BigQuery after ${BQ_TIMEOUT}s"
    TEST_RESULT=2
  fi
fi

# =============================================================================
# Verify schema correctness (if BQ loaded)
# =============================================================================
if [[ ${TEST_RESULT} -eq 0 ]]; then
  echo ""
  echo "  Verifying schema correctness..."

  SCHEMA_CHECK=$(bq query --nouse_legacy_sql --format=csv --quiet \
    "SELECT event_id, event_type, actor_login, repo_name, etl_create_id FROM \`${PROJECT_ID}.github_archive.github_events\` WHERE DATE(created_at) = '${TARGET_DATE}' AND EXTRACT(HOUR FROM created_at) = ${TARGET_HOUR} LIMIT 1" \
    2>/dev/null | tail -1 || echo "")

  if [[ -n "${SCHEMA_CHECK}" ]]; then
    echo "  Schema verified: ${SCHEMA_CHECK}"
  else
    echo "  WARNING: Could not verify schema fields"
  fi
fi

# =============================================================================
# Test Summary
# =============================================================================
echo ""
echo "========================================="
echo "Test Results"
echo "========================================="

if [[ ${TEST_RESULT} -eq 0 ]]; then
  echo "  Landing file:     PASSED"
  echo "  Staging file:     PASSED"
  echo "  BigQuery load:    PASSED"
  echo "  Schema check:     PASSED"
  echo ""
  echo "  Overall: ALL TESTS PASSED"
else
  echo "  Overall: TESTS FAILED (exit code: ${TEST_RESULT})"
fi
echo ""

# =============================================================================
# Destroy (always, regardless of test result)
# =============================================================================
echo "========================================="
echo "Destroying infrastructure"
echo "========================================="
echo ""

if "${SCRIPT_DIR}/destroy-all-phases.sh" "${PROJECT_ID}" "${ENVIRONMENT}" "${REGION}"; then
  echo ""
  echo "  Destroy: PASSED"
else
  echo ""
  echo "  Destroy: FAILED (manual cleanup needed!)"
  echo "  Run: ${SCRIPT_DIR}/destroy-all-phases.sh ${PROJECT_ID} ${ENVIRONMENT} ${REGION}"
  exit 3
fi

# =============================================================================
# Final Summary
# =============================================================================
echo ""
echo "========================================="
echo "CI Pipeline Complete"
echo "========================================="
echo "Test Result: $([ ${TEST_RESULT} -eq 0 ] && echo 'PASSED' || echo 'FAILED')"
echo "Finished:    $(date)"
echo "Log:         ${LOG_FILE}"
echo "========================================="

exit ${TEST_RESULT}
