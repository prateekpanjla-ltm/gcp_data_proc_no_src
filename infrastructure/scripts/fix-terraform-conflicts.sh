#!/bin/bash
# Fix Terraform State Conflicts
# Usage: ./fix-terraform-conflicts.sh <PROJECT_ID>
#
# This script imports existing GCP resources into Terraform state
# to resolve Error 409 (already exists) conflicts

set -e

PROJECT_ID="${1:-beaming-glyph-489707-b8}"
REGION="us-central1"

echo "========================================="
echo "Fixing Terraform State Conflicts"
echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"
echo "========================================="
echo ""

# Change to terraform directory
cd "$(dirname "$0")/../terraform"

echo "Step 1: Initializing Terraform..."
terraform init
echo ""

echo "Step 2: Checking current state..."
echo "Current resources in state:"
terraform state list
echo ""

echo "Step 3: Importing Artifact Registry Repository..."
if terraform state show google_artifact_registry_repository.data_pipeline_repo >/dev/null 2>&1; then
  echo "  ℹ Repository already in state, skipping import"
else
  echo "  Importing repository..."
  if terraform import google_artifact_registry_repository.data_pipeline_repo \
    projects/${PROJECT_ID}/locations/${REGION}/repositories/data-pipeline-repo 2>&1; then
    echo "  ✓ Repository imported successfully"
  else
    echo "  ⚠ Import failed (may not exist yet)"
  fi
fi
echo ""

echo "Step 4: Importing Service Accounts..."
SERVICE_ACCOUNTS=(
  "google_service_account.github_archive_downloader:github-archive-downloader"
  "google_service_account.github_archive_processor:github-archive-processor"
  "google_service_account.github_archive_bq_loader:github-archive-bq-loader"
  "google_service_account.phase2_eventarc_invoker:phase2-eventarc-invoker"
  "google_service_account.phase3_eventarc_invoker:phase3-eventarc-invoker"
)

for sa in "${SERVICE_ACCOUNTS[@]}"; do
  IFS=':' read -r resource sa_email <<< "$sa"

  if terraform state show "$resource" >/dev/null 2>&1; then
    echo "  ℹ $resource already in state, skipping"
  else
    echo "  Importing $resource..."
    if terraform import "$resource" \
      projects/${PROJECT_ID}/serviceAccounts/${sa_email}@${PROJECT_ID}.iam.gserviceaccount.com 2>&1; then
      echo "  ✓ $resource imported successfully"
    else
      echo "  ⚠ Import failed (may not exist yet)"
    fi
  fi
done
echo ""

echo "Step 5: Running Terraform Plan to verify..."
if terraform plan -var="project_id=${PROJECT_ID}" -var="environment=test" -var="region=${REGION}"; then
  echo ""
  echo "✅ State conflicts resolved!"
  echo ""
  echo "You can now run: terraform apply"
else
  echo ""
  echo "⚠ There may still be conflicts. Review the plan output above."
  echo ""
  echo "Alternative: Delete conflicting resources and recreate:"
  echo "  ./cleanup-terraform-conflicts.sh ${PROJECT_ID}"
fi
