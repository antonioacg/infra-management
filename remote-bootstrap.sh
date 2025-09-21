#!/bin/bash
set -e

# Enterprise-Ready Homelab Remote Bootstrap v3.0
# Single-command remote deployment with complete automation
# Usage: curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/remote-bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s homelab

# Load centralized logging library
eval "$(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"

# Parse command line arguments for enterprise scaling
NODE_COUNT=1
RESOURCE_TIER="small"
WORK_DIR="$HOME/platform-bootstrap"
GITHUB_ORG="antonioacg"

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
            echo "Unknown parameter: $1"
            echo "Usage: --nodes=N --tier=SIZE"
            exit 1
            ;;
    esac
done

# Repository URLs
INFRA_MGMT_REPO="https://github.com/${GITHUB_ORG}/infra-management.git"
INFRA_REPO="https://github.com/${GITHUB_ORG}/infra.git"
DEPLOYMENTS_REPO="https://github.com/${GITHUB_ORG}/deployments.git"

validate_token() {
    # Check GitHub token
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_error "GITHUB_TOKEN environment variable required"
        echo
        echo "Usage:"
        echo "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/main/remote-bootstrap.sh | GITHUB_TOKEN=\"ghp_xxx\" bash -s -- --nodes=N --tier=SIZE"
        echo
        echo "Get token at: https://github.com/settings/tokens"
        echo "Required scopes: repo, workflow"
        exit 1
    fi
    log_success "GitHub token validated"
}

show_banner() {
    print_banner "🚀 Enterprise Platform Remote Bootstrap" "Terraform-First Architecture" "Resources: $NODE_COUNT nodes, $RESOURCE_TIER tier"
}

run_phase_0() {
    log_info "Running Phase 0 (Environment + Tools validation)..."

    # Use our perfected Phase 0 script
    log_info "Executing remote Phase 0 script..."
    if curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/main/remote-bootstrap-phase0.sh | GITHUB_TOKEN="$GITHUB_TOKEN" bash -s -- --nodes="$NODE_COUNT" --tier="$RESOURCE_TIER"; then
        log_success "Phase 0 completed successfully"
    else
        log_error "Phase 0 failed"
        exit 1
    fi
}

setup_workspace() {
    log_info "Setting up workspace directory..."

    # Create work directory
    if [[ -d "$WORK_DIR" ]]; then
        log_warning "Workspace exists, backing up to ${WORK_DIR}.backup.$(date +%s)"
        mv "$WORK_DIR" "${WORK_DIR}.backup.$(date +%s)"
    fi

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    log_success "Workspace created: $WORK_DIR"
}

clone_repositories() {
    log_info "Cloning required repositories..."

    # Clone all repositories in parallel for speed
    {
        log_info "  Cloning infra-management..."
        git clone --depth 1 "$INFRA_MGMT_REPO" infra-management &
        MGMT_PID=$!

        log_info "  Cloning infra..."
        git clone --depth 1 "$INFRA_REPO" infra &
        INFRA_PID=$!

        log_info "  Cloning deployments..."
        git clone --depth 1 "$DEPLOYMENTS_REPO" deployments &
        DEPLOY_PID=$!

        # Wait for all clones to complete
        wait $MGMT_PID && log_success "  ✅ infra-management cloned"
        wait $INFRA_PID && log_success "  ✅ infra cloned"
        wait $DEPLOY_PID && log_success "  ✅ deployments cloned"
    }

    log_success "All repositories cloned successfully"
}

install_tools() {
    log_info "Installing required tools..."

    # Use the comprehensive tool installation script
    if [[ -f "infra-management/scripts/install-tools.sh" ]]; then
        log_info "Running automated tool installation..."
        bash infra-management/scripts/install-tools.sh
        log_success "Tools installed successfully"
    else
        log_error "Tool installation script not found"
        exit 1
    fi
}

verify_prerequisites() {
    log_info "Verifying all prerequisites..."

    local required_tools=("kubectl" "terraform" "helm" "flux" "jq")
    local missing_tools=()

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            log_success "  ✅ $tool available"
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

    # Set working directory for all operations
    export WORKSPACE_ROOT="$WORK_DIR"

    log_success "Environment configured"
}

execute_bootstrap() {
    log_info "Executing 5-phase Terraform-first bootstrap..."

    cd "$WORK_DIR/infra-management"

    # Ensure the bootstrap script is executable
    chmod +x scripts/bootstrap.sh

    # Execute the main bootstrap with proper environment
    GITHUB_TOKEN="$GITHUB_TOKEN" ./scripts/bootstrap.sh "$ENVIRONMENT"
}

cleanup_on_error() {
    local exit_code=$?
    local line_number=$1

    if [[ $exit_code -ne 0 ]]; then
        echo
        log_error "Bootstrap failed at line $line_number with exit code $exit_code"
        echo
        echo "Debugging information:"
        echo "  • Workspace: $WORK_DIR"
        echo "  • Environment: $ENVIRONMENT"
        echo "  • Architecture: $DETECTED_OS/$DETECTED_ARCH"
        echo "  • Failed phase: $(get_current_phase)"
        echo
        echo "Recovery options:"
        echo "  1. Inspect logs: find $WORK_DIR -name '*.log' -type f"
        echo "  2. Manual retry: cd $WORK_DIR/infra-management && GITHUB_TOKEN=\"\$GITHUB_TOKEN\" ./scripts/bootstrap.sh $ENVIRONMENT"
        echo "  3. Clean retry: rm -rf $WORK_DIR && curl ... (run bootstrap again)"
        echo
        log_info "Workspace preserved for debugging: $WORK_DIR"
        exit $exit_code
    fi
}

get_current_phase() {
    if [[ ! -d "$WORK_DIR" ]]; then
        echo "Phase 0: Environment Validation"
    elif [[ ! -d "$WORK_DIR/infra-management" ]]; then
        echo "Phase 1: Workspace Setup"
    elif ! command -v terraform >/dev/null 2>&1; then
        echo "Phase 2: Tool Installation"
    elif [[ -z "$GITHUB_TOKEN" ]]; then
        echo "Phase 3: Configuration"
    else
        echo "Phase 4: Bootstrap Execution"
    fi
}

rollback_on_failure() {
    log_warning "Attempting rollback..."

    # Stop any running k3s services
    if command -v k3s >/dev/null 2>&1; then
        sudo systemctl stop k3s 2>/dev/null || true
        sudo k3s-uninstall.sh 2>/dev/null || true
    fi

    # Clean up any partial installations
    sudo rm -rf /usr/local/bin/kubectl /usr/local/bin/terraform /usr/local/bin/helm /usr/local/bin/flux 2>/dev/null || true

    log_success "Rollback completed"
}

print_success_message() {
    echo
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                   🎉 BOOTSTRAP COMPLETE!                  ║"
    echo "╠════════════════════════════════════════════════════════════╣"
    echo "║  Environment: $ENVIRONMENT                                  ║"
    echo "║  Workspace: $WORK_DIR                        ║"
    echo "║                                                            ║"
    echo "║  Next steps:                                               ║"
    echo "║  • Check status: kubectl get pods -A                      ║"
    echo "║  • Access Vault: kubectl port-forward -n vault svc/vault  ║"
    echo "║    8200:8200                                               ║"
    echo "║  • View logs: kubectl logs -n flux-system -l app=flux     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main() {
    # Set up comprehensive error handling
    trap 'cleanup_on_error $LINENO' ERR
    trap 'log_warning "Script interrupted by user"; rollback_on_failure; exit 130' INT TERM

    validate_token
    show_banner

    log_phase "Phase 0: Environment + Tools Validation"
    run_phase_0

    log_phase "Phase 1: Workspace Setup"
    setup_workspace
    clone_repositories

    log_phase "Phase 2: Tool Installation"
    install_tools
    verify_prerequisites

    log_phase "Phase 3: Configuration"
    configure_environment

    log_phase "Phase 4: Bootstrap Execution"
    execute_bootstrap

    log_phase "Phase 5: Completion"
    print_success_message
}

# Execute main function with all arguments
main "$@"