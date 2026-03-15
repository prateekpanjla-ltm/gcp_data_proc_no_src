#!/bin/bash
# Test Phase 1 Required IAM Permissions for Terraform Deployer Service Account
# Usage: ./test-phase1-permissions.sh [PROJECT_ID] [ENVIRONMENT]
#
# Example:
#   ./test-phase1-permissions.sh dev-dataprocessing-489305 dev

set -e

# =============================================================================
# Configuration
# =============================================================================
PROJECT_ID="${1:-${PROJECT_ID}}"
ENVIRONMENT="${2:-dev}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: PROJECT_ID not set."
  echo "Usage: $0 <PROJECT_ID> [ENVIRONMENT]"
  exit 1
fi

SA_ID="${ENVIRONMENT}-terraform-deployer"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# =============================================================================
# Check if Policy Troubleshooter API is enabled
# =============================================================================
echo "Step 1: Checking Policy Troubleshooter API..."
if ! gcloud services list --enabled --project="$PROJECT_ID" 2>/dev/null | grep -q "policytroubleshooter"; then
  echo "  ⚠ Policy Troubleshooter API is not enabled"
  echo "  Enable with: gcloud services enable policytroubleshooter.googleapis.com --project=$PROJECT_ID"
  echo ""
  read -p "Enable it now? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    gcloud services enable policytroubleshooter.googleapis.com --project="$PROJECT_ID"
    echo "  ✓ API enabled"
  else
    echo "  Cannot proceed without Policy Troubleshooter API"
    exit 1
  fi
else
  echo "  ✓ Policy Troubleshooter API is enabled"
fi
echo ""

# =============================================================================
# Test Permissions
# =============================================================================
echo "========================================="
echo "Testing Phase 1 Required Permissions"
echo "========================================="
echo "Service Account: $SA_EMAIL"
echo "Project: $PROJECT_ID"
echo ""

# Define permissions to test with descriptions
declare -a TESTS=(
  "iam.serviceAccounts.create|Create service accounts (downloader, scheduler SAs)"
  "storage.buckets.create|Create GCS buckets (landing zone bucket)"
  "run.jobs.create|Create Cloud Run Jobs (download job)"
  "run.jobs.update|Update Cloud Run Jobs"
  "cloudscheduler.jobs.create|Create Cloud Scheduler jobs (hourly trigger)"
  "iam.serviceAccounts.actAs|Impersonate service accounts (required for Cloud Run)"
  "resourcemanager.projects.setIamPolicy|Set IAM policies on project resources"
  "iam.serviceAccounts.setIamPolicy|Set IAM policy on service accounts"
  "storage.buckets.setIamPolicy|Set IAM policy on buckets"
  "artifactregistry.repositories.create|Create Artifact Registry repositories"
  "artifactregistry.repositories.uploadArtifacts|Push container images"
)

# Counters
PASSED=0
FAILED=0

# Test each permission
for test in "${TESTS[@]}"; do
  IFS='|' read -r perm desc <<< "$test"

  echo "─────────────────────────────────────────"
  echo "Testing: $perm"
  echo "Purpose: $desc"

  # Run policy troubleshoot
  result=$(gcloud policy-troubleshoot iam \
    "//cloudresourcemanager.googleapis.com/projects/$PROJECT_ID" \
    --permission="$perm" \
    --principal-email="$SA_EMAIL" \
    --impersonate-service-account="$SA_EMAIL" 2>&1 || echo "ERROR")

  # Check result (look for 'access: GRANTED' at the start of line)
  if echo "$result" | grep -q "^access: GRANTED"; then
    echo "Status: ✅ GRANTED"
    PASSED=$((PASSED + 1))
  else
    echo "Status: ❌ DENIED or ERROR"
    FAILED=$((FAILED + 1))
    # Show the access line for debugging
    echo "$result" | grep -E "^access:" || echo "  No access line found in output"
  fi
  echo ""
done

# =============================================================================
# Summary
# =============================================================================
echo "========================================="
echo "Summary"
echo "========================================="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [[ $FAILED -eq 0 ]]; then
  echo "✅ All Phase 1 permissions are granted!"
  echo "You can proceed with Phase 1 deployment."
else
  echo "❌ Some permissions are missing."
  echo ""
  echo "To grant the Editor role (broad permissions):"
  echo "  gcloud projects add-iam-policy-binding $PROJECT_ID \\"
  echo "    --member=\"serviceAccount:$SA_EMAIL\" \\"
  echo "    --role=\"roles/editor\""
  echo ""
  echo "Or grant specific roles based on failed tests."
  exit 1
fi
