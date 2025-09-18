#!/bin/bash
set -e

# Enterprise-Ready Homelab Bootstrap v2.0
# Terraform-First Architecture with 5-Phase Orchestration

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

# Configuration
ENVIRONMENT=${1:-homelab}  # homelab or business
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

validate_environment() {
    log_info "Validating environment..."

    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_error "GITHUB_TOKEN environment variable required"
        echo "Usage: GITHUB_TOKEN=\"ghp_xxx\" ./bootstrap.sh [homelab|business]"
        exit 1
    fi

    if [[ ! "$ENVIRONMENT" =~ ^(homelab|business)$ ]]; then
        log_error "Environment must be 'homelab' or 'business'"
        exit 1
    fi

    log_success "Environment validated: $ENVIRONMENT phase"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check required commands (kubectl comes from k3s in Phase 1)
    local missing_tools=()
    for cmd in curl terraform helm flux; do
        if ! command -v $cmd >/dev/null 2>&1; then
            missing_tools+=("$cmd")
        fi
    done

    # If tools are missing, try to install them automatically
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_warning "Missing tools: ${missing_tools[*]}"
        log_info "Attempting automatic tool installation..."

        if [[ -f "$SCRIPT_DIR/install-tools.sh" ]]; then
            bash "$SCRIPT_DIR/install-tools.sh"

            # Re-check after installation
            local still_missing=()
            for cmd in "${missing_tools[@]}"; do
                if ! command -v $cmd >/dev/null 2>&1; then
                    still_missing+=("$cmd")
                fi
            done

            if [[ ${#still_missing[@]} -gt 0 ]]; then
                log_error "Failed to install tools: ${still_missing[*]}"
                exit 1
            fi

            log_success "Tools installed automatically"
        else
            log_error "Tool installation script not found. Please install manually: ${missing_tools[*]}"
            exit 1
        fi
    fi

    log_success "Prerequisites satisfied"
}

main() {
    echo -e "${GREEN}"
    echo "🚀 Enterprise-Ready Homelab Bootstrap v2.0"
    echo "📋 Terraform-First Architecture"
    echo "🎯 Environment: $ENVIRONMENT"
    echo -e "${NC}"

    validate_environment
    check_prerequisites

    # Phase 1: System preparation
    log_info "📦 Phase 1: System preparation..."
    "$SCRIPT_DIR/01-system-prep.sh" "$ENVIRONMENT"

    # Phase 2: Bootstrap state backend
    log_info "🗃️ Phase 2: Bootstrap state backend..."
    "$SCRIPT_DIR/02-bootstrap-state.sh" "$ENVIRONMENT"

    # Phase 3: Main infrastructure
    log_info "🏗️ Phase 3: Main infrastructure..."
    "$SCRIPT_DIR/03-main-infra.sh" "$ENVIRONMENT"

    # Phase 4: Vault initialization
    log_info "🔐 Phase 4: Vault configuration..."
    "$SCRIPT_DIR/04-vault-init.sh" "$ENVIRONMENT"

    # Phase 5: GitOps activation
    log_info "⚡ Phase 5: GitOps activation..."
    "$SCRIPT_DIR/05-gitops-activate.sh" "$ENVIRONMENT"

    echo -e "${GREEN}"
    echo "✅ Bootstrap complete!"
    echo "🎯 Environment: $ENVIRONMENT phase"
    echo "🔍 Check status with: kubectl get pods -A"
    echo "🌐 Access Vault: kubectl port-forward -n vault svc/vault 8200:8200"
    echo -e "${NC}"
}

main "$@"