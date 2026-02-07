#!/bin/bash
set -euo pipefail

# Enterprise-Ready Platform Bootstrap - Phase 0 Testing
# Tests ONLY: environment validation, architecture detection, and tool installation
# Usage: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase0.sh | GITHUB_TOKEN="test" bash -s -- --nodes=1 --tier=small

# Configuration - set defaults before imports
GITHUB_ORG="${GITHUB_ORG:-antonioacg}"
GIT_REF="${GIT_REF:-main}"
NODE_COUNT=1
RESOURCE_TIER="small"

# Pinned tool versions - required, no defaults for critical dependencies
FLUX_VERSION="${FLUX_VERSION:-2.4.0}"
export FLUX_VERSION

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
                echo "  GITHUB_ORG          GitHub organization/user (default: antonioacg)"
                echo "  FLUX_VERSION        Flux CLI version to install (default: 2.4.0)"
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

# PRIVATE: Cleanup function for Phase 0
_cleanup() {
    local exit_code=$?

    # Phase 0 has no resources to clean up (just validation and tool installation)

    # Show appropriate message based on exit code
    if [[ $exit_code -eq 130 ]]; then
        log_warning "[Phase 0] ⚠️  Script interrupted by user"
    elif [[ $exit_code -ne 0 ]]; then
        log_error "[Phase 0] ❌ Phase 0 failed with exit code $exit_code"
        log_info ""
        log_info "🔍 Debugging information:"
        log_info "  • Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"
        log_info "  • Architecture: ${DETECTED_OS:-unknown}/${DETECTED_ARCH:-unknown}"
        log_info ""
        log_info "🔧 Recovery options:"
        log_info "  1. Check system requirements: curl, git"
        log_info "  2. Verify GITHUB_TOKEN is set correctly"
        log_info "  3. Retry Phase 0: curl ... (run this script again)"
        log_info ""
    fi
}

# PRIVATE: Validate environment prerequisites for Phase 0
_validate_environment() {
    log_info "[Phase 0a] Validating environment and prerequisites..."

    # Check GitHub token (allow "test" for Phase 0 testing)
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
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

# PRIVATE: Validate GitHub token and repository access
_validate_github_access() {
    log_info "[Phase 0a] Validating GitHub access and configuration..."

    local api_response
    local http_code
    local response_headers

    # Query GitHub API for account (validates token and GITHUB_ORG)
    # Capture both headers and body to check OAuth scopes
    response_headers=$(mktemp)
    api_response=$(curl -sfL \
        -D "$response_headers" \
        -w "%{http_code}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/users/${GITHUB_ORG}" 2>/dev/null)

    http_code="${api_response: -3}"
    api_response="${api_response%???}"

    if [[ "$http_code" == "401" ]]; then
        rm -f "$response_headers"
        log_error "[Phase 0a] GitHub token is invalid or expired"
        log_error "[Phase 0a] Check GITHUB_TOKEN environment variable"
        log_info "[Phase 0a] Get token at: https://github.com/settings/tokens (scopes: repo, workflow)"
        exit 1
    elif [[ "$http_code" == "404" ]]; then
        rm -f "$response_headers"
        log_error "[Phase 0a] GitHub account '${GITHUB_ORG}' not found"
        log_error "[Phase 0a] Check GITHUB_ORG environment variable"
        exit 1
    elif [[ "$http_code" != "200" ]]; then
        rm -f "$response_headers"
        log_error "[Phase 0a] GitHub API returned unexpected status: ${http_code}"
        log_error "[Phase 0a] Response: ${api_response}"
        exit 1
    fi

    # Validate token has required scopes (repo, workflow)
    local token_scopes
    token_scopes=$(grep -i "^x-oauth-scopes:" "$response_headers" | cut -d: -f2- | tr -d ' \r' || echo "")
    rm -f "$response_headers"

    if [[ -n "$token_scopes" ]]; then
        log_debug "[Phase 0a] Token scopes: $token_scopes"

        local missing_scopes=""

        # Check for 'repo' scope (required for private repo access)
        if [[ ! "$token_scopes" =~ (^|,)repo(,|$) ]]; then
            missing_scopes="repo"
        fi

        # Check for 'workflow' scope (required for GitHub Actions)
        if [[ ! "$token_scopes" =~ (^|,)workflow(,|$) ]]; then
            if [[ -n "$missing_scopes" ]]; then
                missing_scopes="$missing_scopes, workflow"
            else
                missing_scopes="workflow"
            fi
        fi

        if [[ -n "$missing_scopes" ]]; then
            log_error "[Phase 0a] GitHub token missing required scopes: $missing_scopes"
            log_error "[Phase 0a] Current scopes: $token_scopes"
            log_info "[Phase 0a] Create a new token at: https://github.com/settings/tokens"
            log_info "[Phase 0a] Required scopes: repo, workflow"
            exit 1
        fi

        log_success "[Phase 0a] ✅ GitHub token scopes validated (repo, workflow)"
    else
        # Fine-grained tokens don't return X-OAuth-Scopes header
        # Fall back to permission checks via API calls
        log_debug "[Phase 0a] No OAuth scopes header (fine-grained token or GitHub App)"
        log_debug "[Phase 0a] Will validate permissions via repository access checks"
    fi

    local account_type
    account_type=$(echo "$api_response" | jq -r '.type // empty')

    if [[ -z "$account_type" ]]; then
        log_error "[Phase 0a] Could not parse GitHub API response"
        log_error "[Phase 0a] Response: ${api_response}"
        exit 1
    fi

    if [[ "$account_type" == "User" ]]; then
        log_success "[Phase 0a] ✅ GitHub account '${GITHUB_ORG}' is a User (personal account)"
    elif [[ "$account_type" == "Organization" ]]; then
        log_success "[Phase 0a] ✅ GitHub account '${GITHUB_ORG}' is an Organization"
    else
        log_error "[Phase 0a] Unknown GitHub account type: '${account_type}'"
        exit 1
    fi

    # Validate access to required repositories
    log_info "[Phase 0a] Validating repository access..."

    local required_repos=("infra-management" "deployments")
    for repo in "${required_repos[@]}"; do
        log_debug "[Phase 0a] Checking access to ${GITHUB_ORG}/${repo}..."

        local repo_response
        local repo_http_code

        repo_response=$(curl -sfL \
            -w "%{http_code}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/repos/${GITHUB_ORG}/${repo}" 2>/dev/null)

        repo_http_code="${repo_response: -3}"

        if [[ "$repo_http_code" == "200" ]]; then
            log_debug "[Phase 0a] ✅ Access to ${GITHUB_ORG}/${repo}: OK"
        elif [[ "$repo_http_code" == "404" ]]; then
            log_error "[Phase 0a] Repository ${GITHUB_ORG}/${repo} not found or no access"
            log_error "[Phase 0a] Ensure repository exists and your token has 'repo' scope"
            exit 1
        else
            log_warning "[Phase 0a] Unexpected status for ${GITHUB_ORG}/${repo}: ${repo_http_code}"
        fi
    done

    log_success "[Phase 0a] ✅ GitHub token and repository access validated"
}


# PRIVATE: Install required tools
_install_tools() {
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

# PRIVATE: Verify all prerequisites are met
_verify_prerequisites() {
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
    export GITHUB_ORG="$GITHUB_ORG"
    export KUBECONFIG="$HOME/.kube/config"

    # Export resource configuration for future bootstrap
    export NODE_COUNT="$NODE_COUNT"
    export RESOURCE_TIER="$RESOURCE_TIER"

    log_success "[Phase 0c] ✅ Environment configured"
}


# PRIVATE: Print success message with next steps
_print_success_message() {
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
    log_info "[Phase 0]   • GitHub: ${GITHUB_ORG}"
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
    # Parse parameters if provided (handles both sourced and direct execution)
    if [[ $# -gt 0 ]]; then
        _parse_parameters "$@"
    fi

    print_banner "🧪 Enterprise Platform Phase 0 Testing" \
                 "📋 Environment + Tools Validation Only" \
                 "🎯 Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"

    log_phase "🚀 Phase 0a: Environment Validation"
    _validate_environment
    _validate_github_access
    detect_system_architecture

    log_phase "🚀 Phase 0b: Tool Installation"
    _install_tools
    _verify_prerequisites

    log_phase "🚀 Phase 0c: Configuration"
    _configure_environment

    log_phase "🚀 Phase 0: Complete!"
    _print_success_message
}

# Only run main when executed directly (not sourced via smart_import)
# Handles: direct execution, curl piping, but NOT sourcing via smart_import
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${BASH_SOURCE[0]}" =~ ^/dev/fd/ ]] || [[ -z "${BASH_SOURCE[0]}" ]]; then
    # Stack cleanup trap , handles both success and failure (including user interrupts)
    stack_trap "_cleanup" EXIT

    main "$@"
fi