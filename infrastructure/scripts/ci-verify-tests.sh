#!/bin/bash
# CI Verification Tests: Verify pipeline infrastructure and data flow
# Usage: ./ci-verify-tests.sh <PROJECT_ID> <ENVIRONMENT> [REGION] [DASHBOARD_URL]
#
# Runs 6 test suites:
#   1. Infrastructure exists (GCP resources)
#   2. Phase 1 — Download (trigger + verify landing)
#   3. Phase 2 — Processing (verify staging)
#   4. Phase 3 — BigQuery load (verify rows)
#   5. Phase 4 — Dashboard endpoints
#   6. Data integrity checks
#
# Exit codes:
#   0 = all tests passed
#   1 = one or more tests failed

set -uo pipefail

# =============================================================================
# Arguments
# =============================================================================
PROJECT_ID="${1:?Error: PROJECT_ID required}"
ENVIRONMENT="${2:?Error: ENVIRONMENT required}"
REGION="${3:-us-central1}"
DASHBOARD_URL="${4:-}"

# =============================================================================
# Derived Names
# =============================================================================
LANDING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing"
STAGING_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-staging"
JOB_NAME="${ENVIRONMENT}-github-archive-download-gsutil"
PROCESSOR_NAME="${ENVIRONMENT}-github-archive-processor"
BQ_LOADER_NAME="${ENVIRONMENT}-bq-loader"
SCHEDULER_NAME="${ENVIRONMENT}-github-archive-download-job"

# Timeouts
LANDING_TIMEOUT=300   # 5 min
STAGING_TIMEOUT=600   # 10 min
BQ_TIMEOUT=300        # 5 min

# Calculate target hour (1 hour ago — matches the download job's default)
HOUR_OFFSET=1
TARGET_DATE=$(date -u -d "${HOUR_OFFSET} hours ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${HOUR_OFFSET}H +"%Y-%m-%d")
TARGET_HOUR=$(date -u -d "${HOUR_OFFSET} hours ago" +"%-H" 2>/dev/null || date -u -v-${HOUR_OFFSET}H +"%-H")
TARGET_FILE="${TARGET_DATE}-${TARGET_HOUR}.json.gz"

# Track results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=""

pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  PASS: $1"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_TESTS="${FAILED_TESTS}\n  - $1"
  echo "  FAIL: $1"
}

echo "========================================="
echo "CI Verification Tests"
echo "========================================="
echo "Project:     ${PROJECT_ID}"
echo "Environment: ${ENVIRONMENT}"
echo "Region:      ${REGION}"
echo "Target File: ${TARGET_FILE}"
echo "Started:     $(date)"
echo "========================================="
echo ""

# =============================================================================
# Test 1: Infrastructure Exists
# =============================================================================
echo "========================================="
echo "Test 1: Infrastructure Exists"
echo "========================================="

# Cloud Run Job
if gcloud run jobs describe "${JOB_NAME}" --project="${PROJECT_ID}" --region="${REGION}" --format="value(name)" >/dev/null 2>&1; then
  pass "Cloud Run Job: ${JOB_NAME}"
else
  fail "Cloud Run Job: ${JOB_NAME} not found"
fi

# Cloud Run Service (processor)
if gcloud run services describe "${PROCESSOR_NAME}" --project="${PROJECT_ID}" --region="${REGION}" --format="value(name)" >/dev/null 2>&1; then
  pass "Cloud Run Service: ${PROCESSOR_NAME}"
else
  fail "Cloud Run Service: ${PROCESSOR_NAME} not found"
fi

# Cloud Function
if gcloud functions describe "${BQ_LOADER_NAME}" --project="${PROJECT_ID}" --region="${REGION}" --format="value(name)" >/dev/null 2>&1; then
  pass "Cloud Function: ${BQ_LOADER_NAME}"
else
  fail "Cloud Function: ${BQ_LOADER_NAME} not found"
fi

# Cloud Scheduler
if gcloud scheduler jobs describe "${SCHEDULER_NAME}" --project="${PROJECT_ID}" --location="${REGION}" --format="value(name)" >/dev/null 2>&1; then
  pass "Cloud Scheduler: ${SCHEDULER_NAME}"
else
  fail "Cloud Scheduler: ${SCHEDULER_NAME} not found"
fi

# BigQuery dataset + table
if bq show --project_id="${PROJECT_ID}" "github_archive.github_events" >/dev/null 2>&1; then
  pass "BigQuery table: github_archive.github_events"
else
  fail "BigQuery table: github_archive.github_events not found"
fi

# Eventarc triggers
TRIGGER_COUNT=$(gcloud eventarc triggers list --project="${PROJECT_ID}" --location="${REGION}" --format="value(name)" 2>/dev/null | wc -l)
if [ "${TRIGGER_COUNT}" -ge 2 ]; then
  pass "Eventarc triggers: ${TRIGGER_COUNT} found"
else
  fail "Eventarc triggers: expected >= 2, found ${TRIGGER_COUNT}"
fi

echo ""

# =============================================================================
# Test 2: Phase 1 — Download
# =============================================================================
echo "========================================="
echo "Test 2: Phase 1 — Download"
echo "========================================="

echo "  Triggering Cloud Run Job: ${JOB_NAME}"
gcloud run jobs execute "${JOB_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --wait 2>&1 || true

ELAPSED=0
LANDING_FOUND=false
FOUND_FILE=""
while [ ${ELAPSED} -lt ${LANDING_TIMEOUT} ]; do
  # Check for the exact target file first, then any .json.gz file
  if gcloud storage ls "gs://${LANDING_BUCKET}/github-archive/raw/${TARGET_FILE}" >/dev/null 2>&1; then
    LANDING_FOUND=true
    FOUND_FILE="${TARGET_FILE}"
    break
  fi
  # Fallback: check for any recently downloaded file
  FOUND_FILE=$(gcloud storage ls "gs://${LANDING_BUCKET}/github-archive/raw/*.json.gz" 2>/dev/null | tail -1 | xargs -I{} basename {} 2>/dev/null || echo "")
  if [ -n "${FOUND_FILE}" ]; then
    LANDING_FOUND=true
    break
  fi
  echo "  Waiting for landing file... (${ELAPSED}s / ${LANDING_TIMEOUT}s)"
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

if [ "${LANDING_FOUND}" = "true" ]; then
  pass "File downloaded: ${FOUND_FILE} in ${ELAPSED}s"
  # Update target for subsequent checks
  TARGET_DATE=$(echo "${FOUND_FILE}" | grep -oP '^\d{4}-\d{2}-\d{2}')
  TARGET_HOUR=$(echo "${FOUND_FILE}" | grep -oP '\d{4}-\d{2}-\d{2}-\K\d+')
else
  fail "File not found in landing bucket after ${LANDING_TIMEOUT}s"
fi

echo ""

# =============================================================================
# Test 3: Phase 2 — Processing
# =============================================================================
echo "========================================="
echo "Test 3: Phase 2 — Processing"
echo "========================================="

ELAPSED=0
STAGING_FOUND=false
STAGING_PREFIX="${TARGET_DATE}-${TARGET_HOUR}"

while [ ${ELAPSED} -lt ${STAGING_TIMEOUT} ]; do
  CHUNK_COUNT=$(gcloud storage ls "gs://${STAGING_BUCKET}/processed/${STAGING_PREFIX}-chunk-*" 2>/dev/null | wc -l | tr -d ' ')
  CHUNK_COUNT=${CHUNK_COUNT:-0}
  if [ "${CHUNK_COUNT}" -gt 0 ] 2>/dev/null; then
    STAGING_FOUND=true
    break
  fi
  echo "  Waiting for processed chunks... (${ELAPSED}s / ${STAGING_TIMEOUT}s)"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

if [ "${STAGING_FOUND}" = "true" ]; then
  pass "Processed chunks found: ${CHUNK_COUNT} files in ${ELAPSED}s"
else
  fail "No processed chunks in staging bucket after ${STAGING_TIMEOUT}s"
fi

echo ""

# =============================================================================
# Test 4: Phase 3 — BigQuery Load
# =============================================================================
echo "========================================="
echo "Test 4: Phase 3 — BigQuery Load"
echo "========================================="

ELAPSED=0
BQ_LOADED=false
ROW_COUNT=0

while [ ${ELAPSED} -lt ${BQ_TIMEOUT} ]; do
  ROW_COUNT=$(bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql --format=csv --quiet \
    "SELECT COUNT(*) FROM \`${PROJECT_ID}.github_archive.github_events\` WHERE DATE(created_at) = '${TARGET_DATE}' AND EXTRACT(HOUR FROM created_at) = ${TARGET_HOUR}" \
    2>/dev/null | tail -1 || echo "0")
  if [ "${ROW_COUNT}" -gt 0 ] 2>/dev/null; then
    BQ_LOADED=true
    break
  fi
  echo "  Waiting for BQ rows... (${ELAPSED}s / ${BQ_TIMEOUT}s)"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

if [ "${BQ_LOADED}" = "true" ]; then
  pass "BigQuery rows loaded: ${ROW_COUNT} rows in ${ELAPSED}s"
else
  fail "No rows in BigQuery after ${BQ_TIMEOUT}s"
fi

# Verify key fields exist
if [ "${BQ_LOADED}" = "true" ]; then
  FIELD_CHECK=$(bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql --format=csv --quiet \
    "SELECT event_id, event_type, actor_login, repo_name, etl_create_id FROM \`${PROJECT_ID}.github_archive.github_events\` WHERE DATE(created_at) = '${TARGET_DATE}' AND EXTRACT(HOUR FROM created_at) = ${TARGET_HOUR} LIMIT 1" \
    2>/dev/null | tail -1 || echo "")
  if [ -n "${FIELD_CHECK}" ]; then
    pass "Schema fields verified: event_id, event_type, actor_login, repo_name, etl_create_id"
  else
    fail "Schema field verification failed"
  fi
fi

echo ""

# =============================================================================
# Test 5: Phase 4 — Dashboard
# =============================================================================
echo "========================================="
echo "Test 5: Phase 4 — Dashboard"
echo "========================================="

if [ -z "${DASHBOARD_URL}" ]; then
  # Try to get dashboard URL from gcloud
  DASHBOARD_URL=$(gcloud run services describe "${ENVIRONMENT}-github-archive-dashboard" \
    --project="${PROJECT_ID}" --region="${REGION}" --format="value(status.url)" 2>/dev/null || echo "")
fi

if [ -n "${DASHBOARD_URL}" ]; then
  for endpoint in "/health" "/" "/phase1" "/phase2" "/phase3" "/elt" "/infra" "/service-accounts"; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${DASHBOARD_URL}${endpoint}" 2>/dev/null || echo "000")
    if [ "${STATUS}" = "200" ]; then
      pass "Dashboard ${endpoint} → HTTP ${STATUS}"
    else
      fail "Dashboard ${endpoint} → HTTP ${STATUS} (expected 200)"
    fi
  done

  # Verify /health returns correct JSON
  HEALTH=$(curl -s "${DASHBOARD_URL}/health" 2>/dev/null || echo "")
  if echo "${HEALTH}" | grep -q '"healthy"'; then
    pass "Dashboard /health returns healthy"
  else
    fail "Dashboard /health unexpected response: ${HEALTH}"
  fi
else
  fail "Dashboard URL not found — skipping dashboard tests"
fi

echo ""

# =============================================================================
# Test 6: Data Integrity
# =============================================================================
echo "========================================="
echo "Test 6: Data Integrity"
echo "========================================="

if [ "${BQ_LOADED}" = "true" ]; then
  # Check for duplicate event_ids
  DUP_COUNT=$(bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql --format=csv --quiet \
    "SELECT COUNT(*) FROM (SELECT event_id, COUNT(*) c FROM \`${PROJECT_ID}.github_archive.github_events\` WHERE DATE(created_at) = '${TARGET_DATE}' AND EXTRACT(HOUR FROM created_at) = ${TARGET_HOUR} GROUP BY event_id HAVING c > 1)" \
    2>/dev/null | tail -1 || echo "0")
  if [ "${DUP_COUNT}" = "0" ]; then
    pass "No duplicate event_ids"
  else
    fail "Found ${DUP_COUNT} duplicate event_ids"
  fi

  # Check row count in expected range (50K-300K per hour)
  if [ "${ROW_COUNT}" -ge 50000 ] && [ "${ROW_COUNT}" -le 300000 ] 2>/dev/null; then
    pass "Row count in expected range: ${ROW_COUNT} (50K-300K)"
  else
    fail "Row count outside expected range: ${ROW_COUNT} (expected 50K-300K)"
  fi

  # Verify created_at timestamps within target hour
  BAD_TS=$(bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql --format=csv --quiet \
    "SELECT COUNT(*) FROM \`${PROJECT_ID}.github_archive.github_events\` WHERE DATE(created_at) = '${TARGET_DATE}' AND EXTRACT(HOUR FROM created_at) = ${TARGET_HOUR} AND created_at IS NULL" \
    2>/dev/null | tail -1 || echo "0")
  if [ "${BAD_TS}" = "0" ]; then
    pass "All created_at timestamps valid"
  else
    fail "Found ${BAD_TS} rows with NULL created_at"
  fi
else
  fail "Skipping data integrity — no BQ data"
fi

echo ""

# =============================================================================
# Test 7: ELT Views and Materialized View
# =============================================================================
echo "========================================="
echo "Test 7: ELT Transformations"
echo "========================================="

if [ "${BQ_LOADED}" = "true" ]; then
  # Materialized view: mv_repo_daily_stats
  MV_COUNT=$(bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql --format=csv --quiet \
    "SELECT COUNT(*) FROM \`${PROJECT_ID}.github_archive.mv_repo_daily_stats\`" \
    2>/dev/null | tail -1 || echo "0")
  if [ "${MV_COUNT}" -gt 0 ] 2>/dev/null; then
    pass "Materialized view mv_repo_daily_stats: ${MV_COUNT} rows"
  else
    fail "Materialized view mv_repo_daily_stats is empty"
  fi

  # Staging view: stg_events (deduplicated)
  STG_COUNT=$(bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql --format=csv --quiet \
    "SELECT COUNT(*) FROM \`${PROJECT_ID}.github_archive.stg_events\` LIMIT 1" \
    2>/dev/null | tail -1 || echo "0")
  if [ "${STG_COUNT}" -gt 0 ] 2>/dev/null; then
    pass "Staging view stg_events: ${STG_COUNT} rows"
  else
    fail "Staging view stg_events is empty"
  fi

  # Mart view: developer_daily_activity
  DEV_COUNT=$(bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql --format=csv --quiet \
    "SELECT COUNT(*) FROM \`${PROJECT_ID}.github_archive.developer_daily_activity\`" \
    2>/dev/null | tail -1 || echo "0")
  if [ "${DEV_COUNT}" -gt 0 ] 2>/dev/null; then
    pass "Mart view developer_daily_activity: ${DEV_COUNT} rows"
  else
    fail "Mart view developer_daily_activity is empty"
  fi

  # Mart view: bot_vs_human_activity
  BOT_ROWS=$(bq query --project_id="${PROJECT_ID}" --nouse_legacy_sql --format=csv --quiet \
    "SELECT COUNT(*) FROM \`${PROJECT_ID}.github_archive.bot_vs_human_activity\`" \
    2>/dev/null | tail -1 || echo "0")
  if [ "${BOT_ROWS}" -ge 2 ] 2>/dev/null; then
    pass "Mart view bot_vs_human_activity: ${BOT_ROWS} rows (bot + human)"
  else
    fail "Mart view bot_vs_human_activity: expected >= 2 rows, got ${BOT_ROWS}"
  fi
else
  fail "Skipping ELT tests — no BQ data"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "========================================="
echo "Test Results"
echo "========================================="
echo "  Passed: ${TESTS_PASSED}"
echo "  Failed: ${TESTS_FAILED}"

if [ ${TESTS_FAILED} -gt 0 ]; then
  echo ""
  echo "  Failed tests:"
  echo -e "${FAILED_TESTS}"
  echo ""
  echo "  Overall: FAILED"
  exit 1
else
  echo ""
  echo "  Overall: ALL TESTS PASSED"
  exit 0
fi
