# Test Project Configuration
# Source this file to set up environment variables for the test project

export PROJECT_ID="beaming-glyph-489707-b8"
export ENVIRONMENT="test"
export REGION="us-central1"

# Derived variables
export PHASE1_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-landing"
export PHASE2_BUCKET="${PROJECT_ID}-${ENVIRONMENT}-github-archive-staging"
export DEPLOYER_SA="${ENVIRONMENT}-terraform-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

echo "✓ Test project configuration loaded:"
echo "  Project ID: $PROJECT_ID"
echo "  Environment: $ENVIRONMENT"
echo "  Region: $REGION"
