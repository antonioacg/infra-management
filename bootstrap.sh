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
STOP_AFTER=""

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
        --stop-after=*)
            STOP_AFTER="${1#*=}"
            shift
            ;;
        --help|-h)
            echo "Enterprise Platform Bootstrap - Main Orchestrator"
            echo "Single-command bootstrap that orchestrates all phases"
            echo ""
            echo "Usage:"
            echo "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN=\"ghp_xxx\" bash -s -- [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --nodes=N            Number of nodes (default: 1)"
            echo "  --tier=SIZE          Resource tier: small|medium|large (default: small)"
            echo "  --environment=ENV    Environment: production|staging|development (default: production)"
            echo "  --start-phase=N      Start from specific phase (default: 0)"
            echo "  --stop-after=PHASE   Stop after specific phase: 0|1|2|2a|2b|2c|2d"
            echo "  --help, -h           Show this help message"
            echo ""
            echo "Phases:"
            echo "  See BOOTSTRAP.md for complete phase definitions"
            echo "  Phase 0: Environment & Tools"
            echo "  Phase 1: k3s + Bootstrap Storage (LOCAL state)"
            echo "  Phase 2: Remote State + Vault Infrastructure"
            echo "  Phase 3-4: Advanced Security + GitOps (planned)"
            echo ""
            echo "Environment Variables:"
            echo "  GITHUB_TOKEN        GitHub token (required)"
            echo "  LOG_LEVEL           Logging level: ERROR|WARN|INFO|DEBUG|TRACE (default: INFO)"
            echo ""
            echo "Examples:"
            echo "  # Full bootstrap from scratch"
            echo "  curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | GITHUB_TOKEN=\"ghp_xxx\" bash -s -- --nodes=1 --tier=small"
            echo ""
            echo "  # Skip Phase 0 (tools already installed)"
            echo "  curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | GITHUB_TOKEN=\"ghp_xxx\" bash -s -- --nodes=1 --tier=small --start-phase=1"
            echo ""
            exit 0
            ;;
        *)
            echo "Error: Unknown parameter: $1"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo "  --nodes=N            Number of nodes (default: 1)"
            echo "  --tier=SIZE          Resource tier: small|medium|large (default: small)"
            echo "  --environment=ENV    Environment name (default: production)"
            echo "  --start-phase=N      Start from specific phase (default: 0)"
            echo "  --stop-after=PHASE   Stop after specific phase: 0|1|2|2a|2b|2c|2d"
            echo "  --help, -h           Show this help message"
            echo ""
            exit 1
            ;;
    esac
done

# Validate GitHub token
if [[ -z "$GITHUB_TOKEN" ]]; then
    log_error "GITHUB_TOKEN environment variable required"
    echo ""
    echo "Run: $0 --help for usage information"
    echo "Get token at: https://github.com/settings/tokens (scopes: repo, workflow)"
    echo ""
    exit 1
fi

print_banner "🚀 Enterprise Platform Bootstrap" "Ultra-streamlined orchestrator" "Environment: $ENVIRONMENT, Resources: $NODE_COUNT nodes, $RESOURCE_TIER tier, start: Phase $START_PHASE"

# Phase 0: Environment + Tools validation
if [[ $START_PHASE -le 0 ]]; then
    log_phase "Phase 0: Environment + Tools validation"

    # Import and rename main to avoid collision
    smart_import "infra-management/scripts/bootstrap-phase0.sh"
    phase0_main() { main "$@"; }
    unset -f main

    if phase0_main --nodes="$NODE_COUNT" --tier="$RESOURCE_TIER"; then
        log_success "Phase 0 completed"
        if [[ "$STOP_AFTER" == "0" ]]; then
            print_banner "✅ Stopped after Phase 0" "Tools validated" "Next: Run with --start-phase=1"
            exit 0
        fi
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

    # Import and rename main to avoid collision with Phase 0
    smart_import "infra-management/scripts/bootstrap-phase1.sh"
    phase1_main() { main "$@"; }
    unset -f main

    # Run Phase 1 without subshell to preserve credentials
    if phase1_main --nodes="$NODE_COUNT" --tier="$RESOURCE_TIER" --preserve-credentials; then
        log_success "Phase 1 completed (credentials preserved for Phase 2)"
        if [[ "$STOP_AFTER" == "1" ]]; then
            print_banner "✅ Stopped after Phase 1" "Foundation ready" "Credentials preserved in memory. Next: Run with --start-phase=2"
            exit 0
        fi
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

    # Build Phase 2 arguments - pass --stop-after if it's a subphase
    PHASE2_ARGS="--nodes=$NODE_COUNT --tier=$RESOURCE_TIER --environment=$ENVIRONMENT --skip-validation"
    if [[ "$STOP_AFTER" =~ ^2[a-d]$ ]]; then
        PHASE2_ARGS="$PHASE2_ARGS --stop-after=$STOP_AFTER"
    fi

    # Import and rename main to avoid collision
    smart_import "infra-management/scripts/bootstrap-phase2.sh"
    phase2_main() { main "$@"; }
    unset -f main

    if phase2_main $PHASE2_ARGS; then
        log_success "Phase 2 completed"

        # Only clean up credentials if we completed full Phase 2 (not a subphase stop)
        if [[ -z "$STOP_AFTER" || "$STOP_AFTER" == "2" ]]; then
            # Clean up credentials after successful Phase 2
            smart_import "infra-management/scripts/lib/credentials.sh"
            clear_bootstrap_credentials
            log_info "🔒 Credentials cleared from memory after successful Phase 2"
        else
            # Subphase stop - preserve credentials
            log_info "🔒 Credentials preserved in memory (stopped at $STOP_AFTER)"
        fi

        if [[ "$STOP_AFTER" =~ ^2[a-d]?$ ]]; then
            print_banner "✅ Stopped after Phase $STOP_AFTER" "Partial Phase 2 complete" "Credentials preserved. Next steps documented above."
            exit 0
        fi
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