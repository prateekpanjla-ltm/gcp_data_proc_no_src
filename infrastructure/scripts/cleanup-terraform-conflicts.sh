#!/bin/bash
# Clean Up Terraform Conflicts (Destructive)
# Usage: ./cleanup-terraform-conflicts.sh <PROJECT_ID>
#
# WARNING: This script DELETES existing resources so Terraform can recreate them
# Use fix-terraform-conflicts.sh instead to preserve existing resources

set -e

PROJECT_ID="${1:-beaming-glyph-489707-b8}"
REGION="us-central1"

echo "========================================="
echo "⚠️  WARNING: DESTRUCTIVE CLEANUP"
echo "========================================="
echo "This will DELETE the following resources in project: ${PROJECT_ID}"
echo ""
echo "  - Artifact Registry Repository: data-pipeline-repo"
echo "  - Service Accounts:"
echo "    • github-archive-downloader"
echo "    • github-archive-processor"
echo "    • github-archive-bq-loader"
echo "    • processor-eventarc-invoker"
echo "    • bq-loader-eventarc-invoker"
echo ""
echo "These resources will be RECREATED by Terraform"
echo ""
read -p "Are you sure? Type 'DELETE' to continue: " -r
echo
if [[ ! $REPLY == "DELETE" ]]; then
  echo "Cancelled."
  exit 1
fi

echo ""
echo "Step 1: Removing Artifact Registry Repository..."
if gcloud artifacts repositories describe data-pipeline-repo \
  --location=${REGION} \
  --project=${PROJECT_ID} >/dev/null 2>&1; then

  echo "  Deleting repository and all images..."
  gcloud artifacts repositories delete data-pipeline-repo \
    --location=${REGION} \
    --project=${PROJECT_ID} \
    --quiet
  echo "  ✓ Repository deleted"
else
  echo "  ℹ Repository doesn't exist, skipping"
fi
echo ""

echo "Step 2: Removing Service Accounts..."
SERVICE_ACCOUNTS=(
  "github-archive-downloader"
  "github-archive-processor"
  "github-archive-bq-loader"
  "processor-eventarc-invoker"
  "bq-loader-eventarc-invoker"
)

for sa_name in "${SERVICE_ACCOUNTS[@]}"; do
  SA_EMAIL="${sa_name}@${PROJECT_ID}.iam.gserviceaccount.com"

  if gcloud iam service-accounts describe ${SA_EMAIL} \
    --project=${PROJECT_ID} >/dev/null 2>&1; then

    echo "  Deleting ${sa_name}..."

    # Remove IAM policy bindings first
    echo "    Removing IAM bindings..."
    gcloud projects get-iam-policy ${PROJECT_ID} \
      --flatten="bindings[].members" \
      --filter="bindings.members:serviceAccount:${SA_EMAIL}" \
      --format="table(bindings.role)" 2>/dev/null | \
      tail -n +2 | \
      while read role; do
        if [[ -n "$role" ]]; then
          gcloud projects remove-iam-policy-binding ${PROJECT_ID} \
            --member="serviceAccount:${SA_EMAIL}" \
            --role="${role}" \
            --quiet >/dev/null 2>&1 || true
        fi
      done

    # Delete the service account
    gcloud iam service-accounts delete ${SA_EMAIL} \
      --project=${PROJECT_ID} \
      --quiet
    echo "    ✓ ${sa_name} deleted"
  else
    echo "  ℹ ${sa_name} doesn't exist, skipping"
  fi
done
echo ""

echo "Step 3: Cleaning Terraform State..."
cd "$(dirname "$0")/../terraform"

# Remove from state if present
for sa_name in "${SERVICE_ACCOUNTS[@]}"; do
  RESOURCE="google_service_account.${sa_name//-/_}"
  if terraform state list | grep -q "^${RESOURCE}$"; then
    echo "  Removing ${RESOURCE} from state..."
    terraform state rm ${RESOURCE} || true
  fi
done

RESOURCE="google_artifact_registry_repository.data_pipeline_repo"
if terraform state list | grep -q "^${RESOURCE}$"; then
  echo "  Removing ${RESOURCE} from state..."
  terraform state rm ${RESOURCE} || true
fi
echo ""

echo "========================================="
echo "✅ Cleanup Complete!"
echo "========================================="
echo ""
echo "You can now run: terraform apply"
echo ""
