#!/bin/bash
set -e

# Enterprise-Ready Platform Remote Bootstrap - Phase 0 Testing
# Tests ONLY: environment validation, architecture detection, and tool installation
# Usage: curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/remote-bootstrap-phase0.sh | GITHUB_TOKEN="test" bash -s --nodes=1 --tier=small

# Load central logging library
if [[ "${DEV_MODE:-false}" == "true" ]]; then
    # Development mode: use relative path
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/lib/logging.sh"
else
    # Production mode: use remote URL
    source <(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/lib/logging.sh)
fi

# Client-specific logging functions (with emojis)
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_phase() { echo -e "${CYAN}🚀 $1${NC}"; }

# Parse command line arguments for enterprise scaling
NODE_COUNT=1
RESOURCE_TIER="small"

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
        *)
            log_error "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

# Configuration
GITHUB_ORG="antonioacg"


validate_environment() {
    log_info "Validating environment and prerequisites..."

    # Check GitHub token (allow "test" for Phase 0 testing)
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_error "GITHUB_TOKEN environment variable required"
        echo
        echo "Usage:"
        echo "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/main/remote-bootstrap-phase0.sh | GITHUB_TOKEN=\"test\" bash -s --nodes=N --tier=SIZE"
        echo
        echo "Parameters:"
        echo "  --nodes=N     Number of nodes (default: 1)"
        echo "  --tier=SIZE   Resource tier: small|medium|large (default: small)"
        echo
        echo "Note: Use GITHUB_TOKEN=\"test\" for Phase 0 testing"
        exit 1
    fi

    # Validate resource parameters
    if [[ ! "$RESOURCE_TIER" =~ ^(small|medium|large)$ ]]; then
        log_error "Resource tier must be 'small', 'medium', or 'large'"
        exit 1
    fi

    if [[ ! "$NODE_COUNT" =~ ^[0-9]+$ ]] || [[ "$NODE_COUNT" -lt 1 ]]; then
        log_error "Node count must be a positive integer"
        exit 1
    fi

    # Check basic system requirements
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required but not installed"
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_error "git is required but not installed"
        exit 1
    fi

    log_success "Resources validated: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier (Phase 0 mode)"
}

detect_architecture() {
    log_info "Detecting system architecture..."

    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$arch" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    case "$os" in
        linux) OS="linux" ;;
        darwin) OS="darwin" ;;
        *)
            log_error "Unsupported operating system: $os"
            exit 1
            ;;
    esac

    log_success "Detected: $OS/$ARCH"
    export DETECTED_ARCH="$ARCH"
    export DETECTED_OS="$OS"
}

install_tools() {
    log_info "Installing required tools remotely..."

    # Execute tool installation script directly via curl pipe
    local install_script_url="https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/main/scripts/install-tools.sh"

    log_info "Executing tool installation script remotely..."
    if curl -sfL "$install_script_url" | bash; then
        log_success "Tools installed successfully"
    else
        log_error "Failed to execute tool installation script from: $install_script_url"
        exit 1
    fi
}

verify_prerequisites() {
    log_info "Verifying all prerequisites..."

    local required_tools=("kubectl" "terraform" "helm" "flux" "jq")
    local missing_tools=()

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            local version=""
            case "$tool" in
                kubectl) version=$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo "unknown") ;;
                terraform) version=$(terraform version -json 2>/dev/null | jq -r .terraform_version || echo "unknown") ;;
                flux) version=$(flux version --client 2>/dev/null | grep 'flux version' | cut -d' ' -f3 || echo "unknown") ;;
                *) version=$(${tool} --version 2>/dev/null | head -1 || echo "unknown") ;;
            esac
            log_success "  ✅ $tool available (${version})"
        else
            log_error "  ❌ $tool missing"
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    log_success "All prerequisites verified"
}

configure_environment() {
    log_info "Configuring environment variables..."

    # Export required environment variables
    export GITHUB_TOKEN="$GITHUB_TOKEN"
    export KUBECONFIG="$HOME/.kube/config"

    # Export resource configuration for future bootstrap
    export NODE_COUNT="$NODE_COUNT"
    export RESOURCE_TIER="$RESOURCE_TIER"

    log_success "Environment configured"
}

cleanup_on_error() {
    local exit_code=$?
    local line_number=$1

    if [[ $exit_code -ne 0 ]]; then
        echo
        log_error "Phase 0 testing failed at line $line_number with exit code $exit_code"
        echo
        echo "Debugging information:"
        echo "  • Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"
        echo "  • Architecture: ${DETECTED_OS:-unknown}/${DETECTED_ARCH:-unknown}"
        echo "  • Failed phase: $(get_current_phase)"
        echo
        echo "Recovery options:"
        echo "  1. Check logs above for specific error details"
        echo "  2. Run cleanup: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/main/scripts/cleanup.sh | bash -s --force"
        echo "  3. Retry Phase 0: curl ... (run this script again)"
        echo
        exit $exit_code
    fi
}

get_current_phase() {
    if ! command -v terraform >/dev/null 2>&1; then
        echo "Phase 0b: Tool Installation"
    elif [[ -z "$GITHUB_TOKEN" ]]; then
        echo "Phase 0c: Configuration"
    else
        echo "Phase 0: Complete"
    fi
}

print_success_message() {
    echo
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                🎉 PHASE 0 TESTING COMPLETE!               ║"
    echo "╠════════════════════════════════════════════════════════════╣"
    echo "║  Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier (Phase 0 mode)          ║"
    echo "║                                                            ║"
    echo "║  ✅ Environment validation successful                      ║"
    echo "║  ✅ Architecture detection working                         ║"
    echo "║  ✅ Tool installation working                              ║"
    echo "║  ✅ Environment configuration ready                        ║"
    echo "║                                                            ║"
    echo "║  Next steps:                                               ║"
    echo "║  • Ready for full remote bootstrap                        ║"
    echo "║  • All prerequisites verified and available                ║"
    echo "║  • System ready for enterprise deployment                 ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo
    echo "🔍 Phase 0 Testing Summary:"
    echo "  • Architecture: $DETECTED_OS/$DETECTED_ARCH"
    echo "  • Tools verified: kubectl, terraform, helm, flux, jq"
    echo "  • Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier configured"
    echo "  • No repositories cloned (minimal Phase 0 testing)"
    echo "  • No workspace created (tools validated only)"
    echo
    echo "🚀 To run full remote bootstrap (Phase 1-5):"
    echo "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/main/remote-bootstrap.sh | GITHUB_TOKEN=\"ghp_xxx\" bash -s --nodes=${NODE_COUNT} --tier=${RESOURCE_TIER}"
    echo
}

main() {
    # Set up comprehensive error handling
    trap 'cleanup_on_error $LINENO' ERR
    trap 'log_warning "Script interrupted by user"; exit 130' INT TERM

    print_banner "🧪 Enterprise Platform Phase 0 Testing" \
                 "📋 Environment + Tools Validation Only" \
                 "🎯 Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"

    log_phase "Phase 0a: Environment Validation"
    validate_environment
    detect_architecture

    log_phase "Phase 0b: Tool Installation"
    install_tools
    verify_prerequisites

    log_phase "Phase 0c: Configuration"
    configure_environment

    log_phase "Phase 0: Complete!"
    print_success_message
}

# Execute main function with all arguments
main "$@"