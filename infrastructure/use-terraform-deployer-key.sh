#!/bin/bash
# =============================================================================
# Helper Script to Configure Terraform Authentication
# =============================================================================
# This script helps you set up the environment to use the service account key
# created by the setup-terraform-deployer.sh script.
#
# Usage:
#   source ./use-terraform-deployer-key.sh
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Detect environment
ENVIRONMENT="${ENVIRONMENT:-test}"
KEY_FILE="${KEY_FILE:-${ENVIRONMENT}-terraform-deployer-key.json}"

log_info "=========================================="
log_info "Terraform Deployer Key Setup"
log_info "=========================================="
echo ""

# Check if key file exists
if [ ! -f "$KEY_FILE" ]; then
    log_error "Key file not found: $KEY_FILE"
    echo ""
    echo "Possible solutions:"
    echo "  1. Run the setup script first:"
    echo "     ./setup-terraform-deployer.sh"
    echo ""
    echo "  2. Set the correct key file path:"
    echo "     export KEY_FILE=/path/to/your-key-file.json"
    echo "     source ./use-terraform-deployer-key.sh"
    echo ""
    echo "  3. Set the correct environment:"
    echo "     export ENVIRONMENT=dev"
    echo "     source ./use-terraform-deployer-key.sh"
    exit 1
fi

log_success "Key file found: $KEY_FILE"

# Check key file permissions
PERMS=$(stat -c "%a" "$KEY_FILE" 2>/dev/null || stat -f "%OLp" "$KEY_FILE" 2>/dev/null || echo "000")
if [ "$PERMS" != "600" ]; then
    log_warning "Key file has insecure permissions: $PERMS"
    log_info "Setting secure permissions (600)..."
    chmod 600 "$KEY_FILE"
    log_success "Permissions updated to 600"
else
    log_success "Key file has secure permissions: $PERMS"
fi

# Export the credentials
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/${KEY_FILE}"
log_success "Environment variable set:"
echo "  GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS"
echo ""

# Test authentication
log_info "Testing authentication..."
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
    log_success "Authentication successful!"
else
    log_error "Authentication failed"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Verify the key file is valid:"
    echo "     cat $KEY_FILE | jq ."
    echo ""
    echo "  2. Check the service account still exists:"
    echo "     gcloud iam service-accounts list"
    echo ""
    echo "  3. Try regenerating the key:"
    echo "     ./setup-terraform-deployer.sh"
    exit 1
fi

echo ""
log_success "=========================================="
log_success "Ready to use Terraform!"
log_success "=========================================="
echo ""
echo "The environment variable is now set for this shell session."
echo ""
echo "To make this persistent, add to your ~/.bashrc or ~/.zshrc:"
echo ""
echo "  echo 'export GOOGLE_APPLICATION_CREDENTIALS=$(pwd)/$KEY_FILE' >> ~/.bashrc"
echo ""
echo "Available commands:"
echo ""
echo "  1. Test Terraform:"
echo "     terraform init"
echo "     terraform plan"
echo ""
echo "  2. Deploy infrastructure:"
echo "     ./infrastructure/deploy-all.sh"
echo ""
echo "  3. Verify authentication:"
echo "     gcloud auth application-default print-access-token"
echo ""
log_warning "Remember:"
echo "  - This key file is sensitive (keep it secure)"
echo "  - Don't commit it to version control"
echo "  - Rotate keys regularly"
echo ""
