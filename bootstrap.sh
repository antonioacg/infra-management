#!/bin/bash
set -e

# Enterprise-Ready Homelab Bootstrap - Wrapper Script
# Calls the new Terraform-first architecture implementation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT=${1:-homelab}

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

echo -e "${GREEN}"
echo "🚀 Enterprise-Ready Homelab Bootstrap"
echo "📋 Redirecting to new Terraform-first architecture"
echo "🎯 Environment: $ENVIRONMENT"
echo -e "${NC}"

# Check if new script exists
if [[ ! -f "$SCRIPT_DIR/scripts/bootstrap.sh" ]]; then
    log_error "New bootstrap script not found at $SCRIPT_DIR/scripts/bootstrap.sh"
    exit 1
fi

log_info "Executing new Terraform-first bootstrap..."

# Execute the new bootstrap script
exec "$SCRIPT_DIR/scripts/bootstrap.sh" "$ENVIRONMENT"