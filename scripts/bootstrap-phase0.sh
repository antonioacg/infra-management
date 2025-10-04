#!/bin/bash
set -e

# Enterprise-Ready Platform Bootstrap - Phase 0 Testing
# Tests ONLY: environment validation, architecture detection, and tool installation
# Usage: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase0.sh | GITHUB_TOKEN="test" bash -s -- --nodes=1 --tier=small

# Configuration - set defaults before imports
GITHUB_ORG="${GITHUB_ORG:-antonioacg}"
GIT_REF="${GIT_REF:-main}"
NODE_COUNT=1
RESOURCE_TIER="small"

# Load import utility and logging library (bash 3.2+ compatible)
eval "$(curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF}/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"
smart_import "infra-management/scripts/lib/system.sh"
smart_import "infra-management/scripts/install-tools.sh"

# PRIVATE: Parse command-line parameters
_parse_parameters() {
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
            --help|-h)
                echo "Enterprise Platform Bootstrap - Phase 0"
                echo "Environment validation, architecture detection, and tool installation"
                echo ""
                echo "Usage:"
                echo "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase0.sh | GITHUB_TOKEN=\"test\" bash -s -- [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --nodes=N           Number of nodes (default: 1)"
                echo "  --tier=SIZE         Resource tier: small|medium|large (default: small)"
                echo "  --help, -h          Show this help message"
                echo ""
                echo "Environment Variables:"
                echo "  GITHUB_TOKEN        GitHub token (use \"test\" for Phase 0 testing)"
                echo "  LOG_LEVEL           Logging level: ERROR|WARN|INFO|DEBUG|TRACE (default: INFO)"
                echo ""
                exit 0
                ;;
            *)
                echo "Error: Unknown parameter: $1"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo "  --nodes=N           Number of nodes (default: 1)"
                echo "  --tier=SIZE         Resource tier: small|medium|large (default: small)"
                echo "  --help, -h          Show this help message"
                echo ""
                exit 1
                ;;
        esac
    done
}


# PRIVATE: Validate environment prerequisites for Phase 0
_validate_environment() {
    log_info "[Phase 0a] Validating environment and prerequisites..."

    # Check GitHub token (allow "test" for Phase 0 testing)
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_error "[Phase 0a] ❌ GITHUB_TOKEN environment variable required"
        echo ""
        echo "Run: $0 --help for usage information"
        echo ""
        exit 1
    fi

    # Validate resource parameters
    if [[ ! "$RESOURCE_TIER" =~ ^(small|medium|large)$ ]]; then
        log_error "[Phase 0a] Resource tier must be 'small', 'medium', or 'large'"
        exit 1
    fi

    if [[ ! "$NODE_COUNT" =~ ^[0-9]+$ ]] || [[ "$NODE_COUNT" -lt 1 ]]; then
        log_error "[Phase 0a] Node count must be a positive integer"
        exit 1
    fi

    # Check basic system requirements
    if ! command -v curl >/dev/null 2>&1; then
        log_error "[Phase 0a] curl is required but not installed"
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_error "[Phase 0a] git is required but not installed"
        exit 1
    fi

    log_success "[Phase 0a] ✅ Resources validated: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier (Phase 0 mode)"
}


install_tools() {
    log_info "[Phase 0b] Installing required tools remotely..."

    # Import tool installation script using smart_import (preserves logging context)
    log_info "[Phase 0b] Importing tool installation script via smart_import..."

    # Execute in subshell to avoid main() function collision
    if (
        smart_import "infra-management/scripts/install-tools.sh"
        main  # Runs install-tools main() in isolated subshell
    ); then
        log_success "[Phase 0b] ✅ Tools installed successfully"
    else
        log_error "[Phase 0b] Failed to execute tool installation"
        exit 1
    fi
}

verify_prerequisites() {
    log_info "[Phase 0b] Verifying all prerequisites..."

    # Use shared verification from install-tools.sh (already imported)
    if verify_tools; then
        log_success "[Phase 0b] ✅ All prerequisites verified"
    else
        log_error "[Phase 0b] Missing tools detected"
        log_info "[Phase 0b] Please install missing tools before continuing"
        exit 1
    fi
}

# PRIVATE: Configure environment variables and paths
_configure_environment() {
    log_info "[Phase 0c] Configuring environment variables..."

    # Export required environment variables
    export GITHUB_TOKEN="$GITHUB_TOKEN"
    export KUBECONFIG="$HOME/.kube/config"

    # Export resource configuration for future bootstrap
    export NODE_COUNT="$NODE_COUNT"
    export RESOURCE_TIER="$RESOURCE_TIER"

    log_success "[Phase 0c] ✅ Environment configured"
}

# PRIVATE: Cleanup resources and provide helpful error information
_cleanup_on_error() {
    local exit_code=$?
    local line_number=$1

    if [[ $exit_code -ne 0 ]]; then
        log_info ""
        log_error "[Phase 0] ❌ Testing failed at line $line_number with exit code $exit_code"
        log_info ""
        log_info "🔍 Debugging information:"
        log_info "  • Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"
        log_info "  • Architecture: ${DETECTED_OS:-unknown}/${DETECTED_ARCH:-unknown}"
        log_info "  • Failed phase: $(get_current_phase)"
        log_info ""
        log_info "🔧 Recovery options:"
        log_info "  1. Check logs above for specific error details"
        log_info "  2. Run cleanup: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF:-main}/scripts/cleanup.sh | bash -s -- --force"
        log_info "  3. Retry Phase 0: curl ... (run this script again)"
        log_info ""
        exit $exit_code
    fi
}

# PRIVATE: Get current bootstrap phase for error reporting
_get_current_phase() {
    if ! command -v terraform >/dev/null 2>&1; then
        echo "Phase 0b: Tool Installation"
    elif [[ -z "$GITHUB_TOKEN" ]]; then
        echo "Phase 0c: Configuration"
    else
        echo "Phase 0: Complete"
    fi
}

print_success_message() {
    log_info ""
    log_success "[Phase 0] 🎉 PHASE 0 TESTING COMPLETE!"
    log_info ""
    log_info "[Phase 0] Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier (Phase 0 mode)"
    log_success "[Phase 0]   ✅ Environment validation successful"
    log_success "[Phase 0]   ✅ Architecture detection working"
    log_success "[Phase 0]   ✅ Tool installation working"
    log_success "[Phase 0]   ✅ Environment configuration ready"
    log_info ""
    log_info "[Phase 0] 🔍 Testing Summary:"
    log_info "[Phase 0]   • Architecture: $DETECTED_OS/$DETECTED_ARCH"
    log_info "[Phase 0]   • Tools verified: kubectl, terraform, helm, flux, jq"
    log_info "[Phase 0]   • Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier configured"
    log_info "[Phase 0]   • No repositories cloned (minimal Phase 0 testing)"
    log_info "[Phase 0]   • No workspace created (tools validated only)"
    log_info ""
    log_info "[Phase 0] 🚀 To run full bootstrap (Phase 1-5):"
    log_info "[Phase 0]   curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN=\"ghp_xxx\" bash -s -- --nodes=${NODE_COUNT} --tier=${RESOURCE_TIER}"
    log_info ""
}

main() {
    # Set up comprehensive error handling
    trap '_cleanup_on_error $LINENO' ERR
    trap 'log_warning "[Phase 0] Script interrupted by user"; exit 130' INT TERM

    print_banner "🧪 Enterprise Platform Phase 0 Testing" \
                 "📋 Environment + Tools Validation Only" \
                 "🎯 Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"

    log_phase "🚀 Phase 0a: Environment Validation"
    _validate_environment
    detect_system_architecture

    log_phase "🚀 Phase 0b: Tool Installation"
    install_tools
    verify_prerequisites

    log_phase "🚀 Phase 0c: Configuration"
    _configure_environment

    log_phase "🚀 Phase 0: Complete!"
    print_success_message
}

# Only run main when executed directly (not sourced via smart_import)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _parse_parameters "$@"
    main "$@"
fi