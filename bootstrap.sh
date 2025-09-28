#!/bin/bash
set -e

# Enterprise-Ready Platform Bootstrap
# Single-command orchestrator that calls individual phase scripts
# Usage: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small --environment=production [--start-phase=N]

# Configuration
GITHUB_ORG="${GITHUB_ORG:-antonioacg}"
GIT_REF="${GIT_REF:-main}"
NODE_COUNT=1
RESOURCE_TIER="small"
ENVIRONMENT="production"
START_PHASE=0

# Load import utility and logging library
eval "$(curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF}/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"

# Parse parameters
while [[ $# -gt 0 ]]; do
    case $1 in
        --nodes=*)
            NODE_COUNT="${1#*=}"
            shift
            ;;
        --tier=*)
            RESOURCE_TIER="${1#*=}"
            shift
            ;;
        --environment=*)
            ENVIRONMENT="${1#*=}"
            shift
            ;;
        --start-phase=*)
            START_PHASE="${1#*=}"
            shift
            ;;
        *)
            log_error "Unknown parameter: $1"
            log_info "Usage: --nodes=N --tier=SIZE --environment=ENV [--start-phase=N]"
            log_info "  --environment=production|staging|development (default: production)"
            log_info "  --start-phase=0  Start from Phase 0 (default)"
            log_info "  --start-phase=1  Start from Phase 1 (skip Phase 0)"
            exit 1
            ;;
    esac
done

# Validate GitHub token
if [[ -z "$GITHUB_TOKEN" ]]; then
    log_error "GITHUB_TOKEN environment variable required"
    log_info ""
    log_info "Usage:"
    log_info "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF}/bootstrap.sh | GITHUB_TOKEN=\"ghp_xxx\" bash -s -- --nodes=N --tier=SIZE --environment=ENV"
    log_info ""
    log_info "Get token at: https://github.com/settings/tokens"
    log_info "Required scopes: repo, workflow"
    exit 1
fi

print_banner "🚀 Enterprise Platform Bootstrap" "Ultra-streamlined orchestrator" "Environment: $ENVIRONMENT, Resources: $NODE_COUNT nodes, $RESOURCE_TIER tier, start: Phase $START_PHASE"

# Phase 0: Environment + Tools validation
if [[ $START_PHASE -le 0 ]]; then
    log_phase "Phase 0: Environment + Tools validation"
    if (
        smart_import "infra-management/scripts/bootstrap-phase0.sh"
        main --nodes="$NODE_COUNT" --tier="$RESOURCE_TIER"
    ); then
        log_success "Phase 0 completed"
    else
        log_error "Phase 0 failed"
        exit 1
    fi
else
    log_info "Skipping Phase 0 (starting from Phase $START_PHASE)"
fi

# Phase 1: k3s + Bootstrap Storage (preserve credentials for Phase 2)
if [[ $START_PHASE -le 1 ]]; then
    log_phase "Phase 1: k3s + Bootstrap Storage"
    if (
        smart_import "infra-management/scripts/bootstrap-phase1.sh"
        main --nodes="$NODE_COUNT" --tier="$RESOURCE_TIER" --preserve-credentials
    ); then
        log_success "Phase 1 completed (credentials preserved for Phase 2)"
    else
        log_error "Phase 1 failed"
        # Import credentials.sh to clear credentials on failure
        smart_import "infra-management/scripts/lib/credentials.sh"
        clear_bootstrap_credentials
        exit 1
    fi
else
    log_info "Skipping Phase 1 (starting from Phase $START_PHASE)"
fi

# Phase 2: State migration + Infrastructure (uses preserved credentials)
if [[ $START_PHASE -le 2 ]]; then
    log_phase "Phase 2: State migration + Infrastructure"
    if (
        smart_import "infra-management/scripts/bootstrap-phase2.sh"
        main --nodes="$NODE_COUNT" --tier="$RESOURCE_TIER" --environment="$ENVIRONMENT" --skip-validation
    ); then
        log_success "Phase 2 completed"
        # Clean up credentials after successful Phase 2
        smart_import "infra-management/scripts/lib/credentials.sh"
        clear_bootstrap_credentials
        log_info "🔒 Credentials cleared from memory after successful Phase 2"
    else
        log_error "Phase 2 failed"
        # Clean up credentials on failure
        smart_import "infra-management/scripts/lib/credentials.sh"
        clear_bootstrap_credentials
        exit 1
    fi
else
    log_info "Skipping Phase 2 (starting from Phase $START_PHASE)"
fi

print_banner "🎉 Bootstrap Complete!" "Platform ready for use" "Next: kubectl get pods -A"