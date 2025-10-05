#!/bin/bash
# Tool Installation Helper for Bootstrap Process

# Remove set -e to prevent silent exits - we want to see errors

# Configuration - set defaults before imports
GITHUB_ORG="${GITHUB_ORG:-antonioacg}"
GIT_REF="${GIT_REF:-main}"
export LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Load import utility and logging library (bash 3.2+ compatible)
eval "$(curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF}/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"
smart_import "infra-management/scripts/lib/system.sh"
smart_import "infra-management/scripts/lib/network.sh"

log_debug "Install tools script starting with LOG_LEVEL=$LOG_LEVEL"

# Definitive tool list - all tools we install/manage
BOOTSTRAP_TOOLS=("kubectl" "terraform" "helm" "flux" "yq" "vault")

# Function to check if a command exists
# PRIVATE: Check if a command exists in PATH
_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Usage: _extract_and_install_binary ZIP_FILE BINARY_NAME [TARGET_DIR]
# PRIVATE: Extract and install binary from downloaded archive
_extract_and_install_binary() {
    local zip_file="$1"
    local binary_name="$2"
    local target_dir="${3:-/usr/local/bin}"

    log_info "📦 Extracting $binary_name from $zip_file..."

    if unzip -q "$zip_file"; then
        if [[ -f "$binary_name" && -s "$binary_name" ]]; then
            chmod +x "$binary_name"
            if sudo mv "$binary_name" "$target_dir/"; then
                log_success "✅ $binary_name successfully installed to $target_dir/"
                rm -f "$zip_file"
                return 0
            else
                log_error "❌ Failed to move $binary_name to $target_dir/"
                rm -f "$binary_name" "$zip_file"
                return 1
            fi
        else
            log_error "❌ Extracted $binary_name binary is empty or missing"
            rm -f "$binary_name" "$zip_file"
            return 1
        fi
    else
        log_error "❌ Failed to unzip $zip_file"
        rm -f "$zip_file"
        return 1
    fi
}

# PRIVATE: Install a package using appropriate package manager
_install_package() {
    local package="$1"

    # macOS doesn't support most Linux system packages
    if [[ "$DETECTED_OS" == "darwin" ]]; then
        log_warning "Package installation not supported on macOS - skipping $package"
        return 0
    fi

    if _command_exists brew; then
        # macOS with Homebrew
        brew install "$package"
    elif _command_exists apt-get; then
        # Ubuntu/Debian
        sudo apt-get update -qq
        sudo apt-get install -y "$package"
    elif _command_exists yum; then
        # CentOS/RHEL
        sudo yum install -y "$package"
    elif _command_exists dnf; then
        # Fedora
        sudo dnf install -y "$package"
    elif _command_exists pacman; then
        # Arch Linux
        sudo pacman -S --noconfirm "$package"
    else
        log_error "No supported package manager found (tried: brew, apt-get, yum, dnf, pacman)"
        log_error "Please install $package manually"
        return 1
    fi
}

# PRIVATE: Install basic system tools
_install_system_tools() {
    log_info "Installing basic system tools"

    local tools=("curl" "wget" "git" "jq" "unzip" "cryptsetup")

    for tool in "${tools[@]}"; do
        if ! _command_exists "$tool"; then
            log_info "Installing $tool"
            _install_package "$tool"
            log_success "$tool installed"
        else
            log_success "$tool already installed"
        fi
    done
}

# PRIVATE: Install kubectl
_install_kubectl() {
    if _command_exists kubectl; then
        log_success "kubectl already installed ($(kubectl version --client --short 2>/dev/null || echo 'version unknown'))"
        return 0
    fi

    log_info "Installing kubectl"

    # Detect OS and architecture

    # Get latest stable version with error handling
    KUBECTL_VERSION=$(curl_with_retry "https://dl.k8s.io/release/stable.txt")
    if [[ -z "$KUBECTL_VERSION" ]]; then
        log_error "Failed to fetch kubectl version"
        return 1
    fi

    # Download and install kubectl using our retry function
    local KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${DETECTED_OS}/${DETECTED_ARCH}/kubectl"

    if curl_with_retry "$KUBECTL_URL" "kubectl"; then
        chmod +x kubectl
        if sudo mv kubectl /usr/local/bin/; then
            log_success "kubectl successfully installed to /usr/local/bin/"
        else
            log_error "Failed to move kubectl to /usr/local/bin/"
            return 1
        fi
    else
        return 1
    fi

    log_success "kubectl ${KUBECTL_VERSION} installed"
}

# PRIVATE: Install Flux CLI
_install_flux() {
    if _command_exists flux; then
        log_success "Flux CLI already installed ($(flux version --client 2>/dev/null | grep 'flux version' || echo 'version unknown'))"
        return 0
    fi
    
    log_info "Installing Flux CLI"

    # Install Flux using official script with error handling
    if curl_with_retry "https://fluxcd.io/install.sh" | sudo bash; then
        log_success "Flux CLI installed successfully"
    else
        log_error "Failed to install Flux CLI - check network connectivity and permissions"
        return 1
    fi
    
}

# PRIVATE: Install Helm
_install_helm() {
    if _command_exists helm; then
        log_success "Helm already installed ($(helm version --short 2>/dev/null || echo 'version unknown'))"
        return 0
    fi

    log_info "Installing Helm"

    # Install Helm using official script with retry logic
    if curl_with_retry "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3" | bash; then
        log_success "Helm installation script executed successfully"
    else
        log_error "Failed to install helm after retry attempts"
        return 1
    fi

    log_success "Helm installed"
}

# PRIVATE: Install Terraform
_install_terraform() {
    if _command_exists terraform; then
        log_success "Terraform already installed ($(terraform version -json 2>/dev/null | jq -r .terraform_version || echo 'version unknown'))"
        return 0
    fi

    log_info "Installing Terraform"

    local TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.6.6}"

    # Download and install Terraform with retry logic
    local TERRAFORM_ZIP="terraform_${TERRAFORM_VERSION}_${DETECTED_OS}_${DETECTED_ARCH}.zip"
    local TERRAFORM_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${TERRAFORM_ZIP}"

    if curl_with_retry "$TERRAFORM_URL" "$TERRAFORM_ZIP"; then
        _extract_and_install_binary "$TERRAFORM_ZIP" "terraform"
    else
        return 1
    fi

    log_success "Terraform ${TERRAFORM_VERSION} installed"
}

# PRIVATE: Install Vault CLI (optional, for debugging)
_install_vault_cli() {
    if _command_exists vault; then
        log_success "Vault CLI already installed ($(vault version 2>/dev/null | head -1 || echo 'version unknown'))"
        return 0
    fi
    
    log_info "Installing Vault CLI"

    local VAULT_VERSION="${VAULT_VERSION:-1.15.2}"

    # Download and install Vault CLI
    local VAULT_ZIP="vault_${VAULT_VERSION}_${DETECTED_OS}_${DETECTED_ARCH}.zip"
    local VAULT_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/${VAULT_ZIP}"

    if curl_with_retry "$VAULT_URL" "$VAULT_ZIP"; then
        _extract_and_install_binary "$VAULT_ZIP" "vault"
    else
        return 1
    fi
    
    log_success "Vault CLI ${VAULT_VERSION} installed"
}

# PRIVATE: Install yq (YAML processor)
_install_yq() {
    if _command_exists yq; then
        log_success "yq already installed ($(yq --version 2>/dev/null || echo 'version unknown'))"
        return
    fi

    log_info "Installing yq"

    local YQ_VERSION="v4.44.1"  # Latest stable version
    local YQ_BINARY_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${DETECTED_OS}_${DETECTED_ARCH}"

    log_debug "Downloading from: $YQ_BINARY_URL"

    # Download binary directly (yq is distributed as a single binary)
    if curl_with_retry "$YQ_BINARY_URL" "yq"; then
        chmod +x yq
        sudo mv yq /usr/local/bin/
        log_success "yq ${YQ_VERSION} installed"
    else
        return 1
    fi
}

# PRIVATE: Parse command-line parameters
_parse_parameters() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --validate)
                _validate_tools
                exit 0
                ;;
            --help|-h)
                echo "Enterprise Platform Tool Installation"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --validate    Show current tool status and system information"
                echo "  --help, -h    Show this help message"
                echo ""
                echo "Environment Variables:"
                echo "  LOG_LEVEL             Set logging level (ERROR|WARN|INFO|DEBUG|TRACE)"
                echo "  USE_LOCAL_IMPORTS     Use local filesystem instead of remote imports"
                echo "  DEBUG_IMPORTS         Show import resolution details"
                echo ""
                exit 0
                ;;
            *)
                echo "Error: Unknown option: $1"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo "  --validate    Show current tool status"
                echo "  --help, -h    Show this help message"
                echo ""
                exit 1
                ;;
        esac
        shift
    done
}

# Verify installations
verify_tools() {
    log_info "Verifying tool installations"

    local failed_tools=()

    for tool in "${BOOTSTRAP_TOOLS[@]}"; do
        if _command_exists "$tool"; then
            local version=""
            case "$tool" in
                kubectl) version=$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo "unknown") ;;
                flux) version=$(flux version --client 2>/dev/null | grep 'flux version' | cut -d' ' -f3 || echo "unknown") ;;
                terraform) version=$(terraform version -json 2>/dev/null | jq -r .terraform_version || echo "unknown") ;;
                vault) version=$(vault version 2>/dev/null | head -1 | cut -d' ' -f2 || echo "unknown") ;;
                yq) version=$(yq --version 2>/dev/null | cut -d' ' -f4 || echo "unknown") ;;
                *) version=$(${tool} --version 2>/dev/null | head -1 || echo "unknown") ;;
            esac
            log_success "$tool installed (${version})"
        else
            log_error "$tool not found"
            failed_tools+=("$tool")
        fi
    done

    if [ ${#failed_tools[@]} -eq 0 ]; then
        log_success "All tools verified successfully"
        return 0
    else
        log_error "Failed to install tools: ${failed_tools[*]}"
        return 1
    fi
}

# Main installation function
main() {
    # Parse parameters if provided (handles both sourced and direct execution)
    if [[ $# -gt 0 ]]; then
        _parse_parameters "$@"
    fi

    print_banner "🔧 Bootstrap Tool Installation" "Installing enterprise platform tools"

    # Detect system architecture first (required for downloads)
    detect_system_architecture

    # Check if running as root (some tools need sudo)
    if [ "$EUID" -eq 0 ]; then
        log_warning "Running as root. Some installations may behave differently."
    fi

    # Install tools in order
    _install_system_tools
    _install_kubectl
    _install_helm
    _install_flux
    _install_terraform
    _install_yq
    _install_vault_cli  # Optional

    echo ""
    verify_tools

    echo ""
    log_success "Tool installation completed!"
    echo ""
    log_info "Installed tools:"
    log_info "  • kubectl - Kubernetes CLI"
    log_info "  • flux - GitOps CLI"
    log_info "  • terraform - Infrastructure as code"
    log_info "  • vault - Secret management CLI (optional)"
    echo ""
}

# Validation function for current state
_validate_tools() {
    log_info "🔍 Tool Installation Validation Report"
    echo ""

    # System information
    log_info "📋 System Information:"
    log_info "  • OS: $(uname -s) (normalized: $DETECTED_OS)"
    log_info "  • Architecture: $(uname -m) (normalized: $DETECTED_ARCH)"
    log_info "  • Kernel: $(uname -r)"
    log_info "  • User: $(whoami)"
    log_info "  • Working Directory: $(pwd)"
    log_info "  • PATH: $PATH"
    echo ""

    # Tool status and versions
    log_info "🔧 Tool Status & Versions:"
    local tools=(
        "curl:curl --version | head -1"
        "wget:wget --version | head -1"
        "git:git version"
        "jq:jq --version"
        "unzip:unzip -v | head -1"
        "kubectl:kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null || echo 'not installed'"
        "flux:flux version --client 2>/dev/null | grep 'flux version' || echo 'not installed'"
        "helm:helm version --short 2>/dev/null || echo 'not installed'"
        "terraform:terraform version -json 2>/dev/null | jq -r .terraform_version || echo 'not installed'"
        "vault:vault version 2>/dev/null | head -1 || echo 'not installed'"
    )

    for tool_info in "${tools[@]}"; do
        local tool="${tool_info%%:*}"
        local version_cmd="${tool_info#*:}"

        if _command_exists "$tool"; then
            local version=$(eval "$version_cmd" 2>/dev/null || echo "version unknown")
            local path=$(command -v "$tool")
            log_success "  ✅ $tool: $version (at: $path)"
        else
            log_error "  ❌ $tool: not found"
        fi
    done

    echo ""
    log_info "🎯 Installation Requirements:"
    local required_tools=("curl" "wget" "git" "jq" "unzip" "kubectl" "flux" "helm" "terraform")
    local missing_tools=()

    for tool in "${required_tools[@]}"; do
        if ! _command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -eq 0 ]; then
        log_success "  ✅ All required tools are installed"
    else
        log_warning "  ⚠️  Missing tools: ${missing_tools[*]}"
        log_info "  💡 Run without --validate to install missing tools"
    fi

    echo ""
    log_info "🔍 Package Manager Detection:"
    if _command_exists brew; then
        log_success "  ✅ Homebrew (macOS): $(brew --version | head -1)"
    elif _command_exists apt-get; then
        log_success "  ✅ apt-get (Ubuntu/Debian): available"
    elif _command_exists yum; then
        log_success "  ✅ yum (CentOS/RHEL): available"
    elif _command_exists dnf; then
        log_success "  ✅ dnf (Fedora): available"
    elif _command_exists pacman; then
        log_success "  ✅ pacman (Arch Linux): available"
    else
        log_error "  ❌ No supported package manager found"
    fi

    echo ""
}

# Run main function if script is executed directly (not sourced via smart_import)
# Handles: direct execution, curl piping, but NOT sourcing via smart_import
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${BASH_SOURCE[0]}" =~ ^/dev/fd/ ]] || [[ -z "${BASH_SOURCE[0]}" ]]; then
    main "$@"
fi