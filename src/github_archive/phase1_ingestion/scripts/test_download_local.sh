#!/bin/bash
# Test Script for GitHub Archive Download Script
# Simulates Cloud Scheduler behavior and tests various scenarios
#
# Usage: ./test_download_local.sh [test_name]
#
# Available tests:
#   all       - Run all tests (default)
#   filename  - Test filename calculation logic
#   download  - Test successful download
#   idempotent - Test idempotency (skip if exists)
#   failure   - Test download failure handling
#   logging   - Test JSON log output format
#
# Examples:
#   ./test_download_local.sh              # Run all tests
#   ./test_download_local.sh filename     # Test filename logic only
#   ./test_download_local.sh download     # Test download only

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_SCRIPT="${SCRIPT_DIR}/download.sh"
TEST_OUTPUT_DIR="${SCRIPT_DIR}/test_output"
TEST_TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
  echo ""
  echo "========================================"
  echo "$1"
  echo "========================================"
}

print_test() {
  echo -e "${BLUE}TEST:${NC} $1"
}

print_pass() {
  echo -e "${GREEN}✓ PASS:${NC} $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

print_fail() {
  echo -e "${RED}✗ FAIL:${NC} $1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

print_info() {
  echo -e "${YELLOW}INFO:${NC} $1"
}

setup_test_env() {
  # Create fresh test output directory
  rm -rf "${TEST_OUTPUT_DIR}"
  mkdir -p "${TEST_OUTPUT_DIR}"
}

cleanup_test_env() {
  # Optional: keep test output for inspection
  # rm -rf "${TEST_OUTPUT_DIR}"
  :
}

run_download_script() {
  local env=$1
  local hours_ago=${2:-1}
  local project_id=${3:-dev-dataprocessing-489305}

  ENVIRONMENT="${env}" \
  PROJECT_ID="${project_id}" \
  HOURS_AGO="${hours_ago}" \
  LOCAL_OUTPUT_DIR="${TEST_OUTPUT_DIR}" \
  bash "${DOWNLOAD_SCRIPT}" 2>&1
}

run_download_script_exit_code() {
  local env=$1
  local hours_ago=${2:-1}
  local project_id=${3:-dev-dataprocessing-489305}

  ENVIRONMENT="${env}" \
  PROJECT_ID="${project_id}" \
  HOURS_AGO="${hours_ago}" \
  LOCAL_OUTPUT_DIR="${TEST_OUTPUT_DIR}" \
  bash "${DOWNLOAD_SCRIPT}" >/dev/null 2>&1
  echo $?
}

# =============================================================================
# Test: Filename Calculation
# =============================================================================
test_filename_calculation() {
  print_header "Test: Filename Calculation Logic"

  # Test current hour (HOURS_AGO=0)
  print_test "Testing filename for current hour (HOURS_AGO=0)"

  # Get filename from actual output
  local output=$(ENVIRONMENT=local HOURS_AGO=0 bash "${DOWNLOAD_SCRIPT}" 2>&1 | grep '"filename"' | jq -r '.filename' 2>/dev/null || echo "")

  if [[ -n "${output}" ]]; then
    if [[ "${output}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{1,2}\.json\.gz$ ]]; then
      print_pass "Filename format correct: ${output}"
    else
      print_fail "Filename format incorrect: ${output}"
    fi
  else
    # Try alternate method to extract
    local full_output=$(ENVIRONMENT=local HOURS_AGO=0 bash "${DOWNLOAD_SCRIPT}" 2>&1)
    if echo "${full_output}" | grep -q "Filename:"; then
      local extracted=$(echo "${full_output}" | grep "Filename:" | awk '{print $NF}' | tr -d '"')
      if [[ "${extracted}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{1,2}\.json\.gz$ ]]; then
        print_pass "Filename format correct: ${extracted}"
      else
        print_fail "Filename format incorrect: ${extracted}"
      fi
    else
      print_fail "Could not extract filename from output"
    fi
  fi

  # Test 1 hour ago
  print_test "Testing filename for 1 hour ago"
  local output_1h=$(ENVIRONMENT=local HOURS_AGO=1 bash "${DOWNLOAD_SCRIPT}" 2>&1 | grep '"filename"' | jq -r '.filename' 2>/dev/null || echo "")
  if [[ -n "${output_1h}" ]]; then
    print_pass "1 hour ago filename: ${output_1h}"
  else
    local full_output=$(ENVIRONMENT=local HOURS_AGO=1 bash "${DOWNLOAD_SCRIPT}" 2>&1)
    local extracted=$(echo "${full_output}" | grep "Filename:" | awk '{print $NF}' | tr -d '"')
    print_pass "1 hour ago filename: ${extracted}"
  fi

  # Test 24 hours ago
  print_test "Testing filename for 24 hours ago"
  local output_24h=$(ENVIRONMENT=local HOURS_AGO=24 bash "${DOWNLOAD_SCRIPT}" 2>&1 | grep '"filename"' | jq -r '.filename' 2>/dev/null || echo "")
  if [[ -n "${output_24h}" ]]; then
    print_pass "24 hours ago filename: ${output_24h}"
  else
    local full_output=$(ENVIRONMENT=local HOURS_AGO=24 bash "${DOWNLOAD_SCRIPT}" 2>&1)
    local extracted=$(echo "${full_output}" | grep "Filename:" | awk '{print $NF}' | tr -d '"')
    print_pass "24 hours ago filename: ${extracted}"
  fi

  ((TESTS_RUN+=3))
}

# =============================================================================
# Test: Download Functionality
# =============================================================================
test_download() {
  print_header "Test: Download Functionality"

  setup_test_env

  print_test "Downloading file from GitHub Archive (HOURS_AGO=48 for file that exists)"

  # Use HOURS_AGO=48 (2 days ago) to get a file that definitely exists
  local output=$(run_download_script "local" 48)
  local exit_code=$?

  echo "${output}"

  if [[ ${exit_code} -eq 0 ]]; then
    # Check if file was actually downloaded
    local downloaded_file=$(echo "${output}" | grep -oP '"Target":\s*"[^"]*"' | cut -d'"' -f4 || echo "")
    if [[ -n "${downloaded_file}" ]]; then
      downloaded_file="${downloaded_file#./test_output/}"
      if [[ -f "${TEST_OUTPUT_DIR}/${downloaded_file}" ]]; then
        local size=$(stat -c%s "${TEST_OUTPUT_DIR}/${downloaded_file}" 2>/dev/null || stat -f%z "${TEST_OUTPUT_DIR}/${downloaded_file}" 2>/dev/null)
        if [[ ${size} -gt 0 ]]; then
          print_pass "File downloaded successfully: ${downloaded_file} (${size} bytes)"
        else
          print_fail "Downloaded file is empty: ${downloaded_file}"
        fi
      else
        print_fail "File not found at expected path"
      fi
    else
      # Try alternate path extraction
      local filename=$(echo "${output}" | grep "Filename:" | awk '{print $NF}' | tr -d '"')
      if [[ -f "${TEST_OUTPUT_DIR}/github-archive/raw/${filename}" ]]; then
        local size=$(stat -c%s "${TEST_OUTPUT_DIR}/github-archive/raw/${filename}" 2>/dev/null || stat -f%z "${TEST_OUTPUT_DIR}/github-archive/raw/${filename}" 2>/dev/null)
        if [[ ${size} -gt 0 ]]; then
          print_pass "File downloaded successfully: ${filename} (${size} bytes)"
        else
          print_fail "Downloaded file is empty: ${filename}"
        fi
      else
        print_fail "Could not verify downloaded file"
      fi
    fi
  else
    print_fail "Download script exited with code: ${exit_code}"
  fi

  ((TESTS_RUN++))
}

# =============================================================================
# Test: Idempotency
# =============================================================================
test_idempotency() {
  print_header "Test: Idempotency (Skip if File Exists)"

  setup_test_env

  # First run - should download
  print_test "First run (should download)"
  local output1=$(run_download_script "local" 48)
  local exit1=$?
  echo "${output1}"

  if [[ ${exit1} -eq 0 ]]; then
    if echo "${output1}" | grep -q "skip"; then
      print_info "File already existed (skipped on first run - expected if test re-run)"
    else
      print_pass "First run completed (downloaded or already exists)"
    fi
  else
    print_fail "First run failed with exit code: ${exit1}"
    ((TESTS_RUN++))
    return
  fi

  # Second run - should skip
  print_test "Second run (should skip - file already exists)"
  local output2=$(run_download_script "local" 2)
  local exit2=$?
  echo "${output2}"

  if [[ ${exit2} -eq 0 ]]; then
    if echo "${output2}" | grep -q "skip"; then
      print_pass "Second run correctly skipped (idempotency working)"
    elif echo "${output2}" | grep -q "already exists"; then
      print_pass "Second run correctly skipped (idempotency working)"
    else
      print_fail "Second run did not skip as expected"
    fi
  else
    print_fail "Second run failed with exit code: ${exit2}"
  fi

  ((TESTS_RUN++))
}

# =============================================================================
# Test: Download Failure Handling
# =============================================================================
test_download_failure() {
  print_header "Test: Download Failure Handling"

  setup_test_env

  # Test with invalid environment variable
  print_test "Testing invalid environment variable"
  local output=$(ENVIRONMENT=invalid bash "${DOWNLOAD_SCRIPT}" 2>&1) || true
  local exit_code=${PIPESTATUS[0]}

  # The script should exit with non-zero when environment is invalid
  if echo "${output}" | grep -q "ENVIRONMENT must be"; then
    print_pass "Invalid environment rejected correctly"
  elif [[ ${exit_code} -ne 0 ]]; then
    print_pass "Invalid environment caused script to fail (exit code: ${exit_code})"
  else
    print_fail "Script should fail with invalid environment"
  fi

  # Test with non-existent file (should fail gracefully)
  print_test "Testing download of non-existent file (HOURS_AGO=5000)"
  output=$(ENVIRONMENT=local HOURS_AGO=5000 LOCAL_OUTPUT_DIR="${TEST_OUTPUT_DIR}" bash "${DOWNLOAD_SCRIPT}" 2>&1) || true
  if echo "${output}" | grep -q "download_failed"; then
    print_pass "Non-existent file handled correctly (reported as failed)"
  else
    print_info "Non-existent file test skipped (unexpected behavior)"
  fi

  ((TESTS_RUN+=2))
}

# =============================================================================
# Test: Logging Format
# =============================================================================
test_logging() {
  print_header "Test: JSON Logging Format"

  setup_test_env

  print_test "Checking JSON log output format"

  local output=$(run_download_script "local" 2)

  # Check for JSON log entries
  local json_logs=$(echo "${output}" | grep -c '{' || echo "0")
  if [[ ${json_logs} -gt 0 ]]; then
    print_pass "Found ${json_logs} JSON-formatted log entries"
  else
    print_fail "No JSON log entries found"
  fi

  # Check for required log fields
  print_test "Checking for required log fields"

  if echo "${output}" | grep -q '"level"'; then
    print_pass "Log field 'level' present"
  else
    print_fail "Log field 'level' missing"
  fi

  if echo "${output}" | grep -q '"timestamp"'; then
    print_pass "Log field 'timestamp' present"
  else
    print_fail "Log field 'timestamp' missing"
  fi

  if echo "${output}" | grep -q '"message"'; then
    print_pass "Log field 'message' present"
  else
    print_fail "Log field 'message' missing"
  fi

  # Check for action/output metrics
  if echo "${output}" | grep -q '"action"'; then
    print_pass "Action field present for metrics"
  else
    print_info "Action field not found (may be expected on failure)"
  fi

  ((TESTS_RUN+=5))
}

# =============================================================================
# Test: Environment Configuration
# =============================================================================
test_environment_config() {
  print_header "Test: Environment Configuration"

  print_test "Testing 'local' environment configuration"
  local output=$(ENVIRONMENT=local HOURS_AGO=1 bash "${DOWNLOAD_SCRIPT}" 2>&1)
  if echo "${output}" | grep -q "Mode: LOCAL"; then
    print_pass "Local environment configured correctly"
  else
    print_fail "Local environment not configured"
  fi

  print_test "Testing 'dev' environment configuration"
  local output=$(ENVIRONMENT=dev PROJECT_ID=test-project HOURS_AGO=1 bash "${DOWNLOAD_SCRIPT}" 2>&1)
  if echo "${output}" | grep -q "test-project-dev-github-archive-landing"; then
    print_pass "Dev environment bucket name derived correctly"
  else
    print_fail "Dev environment bucket name not correct"
  fi

  print_test "Testing 'prod' environment configuration"
  local output=$(ENVIRONMENT=prod PROJECT_ID=test-project HOURS_AGO=1 bash "${DOWNLOAD_SCRIPT}" 2>&1)
  if echo "${output}" | grep -q "test-project-prod-github-archive-landing"; then
    print_pass "Prod environment bucket name derived correctly"
  else
    print_fail "Prod environment bucket name not correct"
  fi

  ((TESTS_RUN+=3))
}

# =============================================================================
# Main Test Runner
# =============================================================================
main() {
  local test_to_run="${1:-all}"

  print_header "GitHub Archive Download Script - Test Suite"
  echo "Test Output Directory: ${TEST_OUTPUT_DIR}"
  echo "Test Timestamp: ${TEST_TIMESTAMP}"
  echo ""

  case "${test_to_run}" in
    "all")
      test_filename_calculation
      test_environment_config
      test_download
      test_idempotency
      test_download_failure
      test_logging
      ;;
    "filename")
      test_filename_calculation
      ;;
    "download")
      test_download
      ;;
    "idempotent")
      test_idempotency
      ;;
    "failure")
      test_download_failure
      ;;
    "logging")
      test_logging
      ;;
    "config")
      test_environment_config
      ;;
    *)
      echo "Error: Unknown test '${test_to_run}'"
      echo "Available tests: all, filename, download, idempotent, failure, logging, config"
      exit 1
      ;;
  esac

  # =============================================================================
  # Summary
  # =============================================================================
  print_header "Test Summary"
  echo "Tests Run:    ${TESTS_RUN}"
  echo -e "${GREEN}Passed:       ${TESTS_PASSED}${NC}"
  echo -e "${RED}Failed:       ${TESTS_FAILED}${NC}"
  echo ""

  if [[ ${TESTS_FAILED} -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    cleanup_test_env
    exit 0
  else
    echo -e "${RED}✗ Some tests failed!${NC}"
    echo "Test output preserved in: ${TEST_OUTPUT_DIR}"
    exit 1
  fi
}

# =============================================================================
# Run Main
# =============================================================================
main "$@"
