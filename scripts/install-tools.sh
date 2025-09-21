#!/bin/bash
# Tool Installation Helper for Bootstrap Process

# Remove set -e to prevent silent exits - we want to see errors

# Load import utility and logging library (bash 3.2+ compatible)
# Propagate LOG_LEVEL from environment if not set
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
eval "$(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"

log_debug "Install tools script starting with LOG_LEVEL=$LOG_LEVEL"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install a package using appropriate package manager
install_package() {
    local package="$1"
    
    if command_exists brew; then
        # macOS with Homebrew
        brew install "$package"
    elif command_exists apt-get; then
        # Ubuntu/Debian
        sudo apt-get update -qq
        sudo apt-get install -y "$package"
    elif command_exists yum; then
        # CentOS/RHEL
        sudo yum install -y "$package"
    elif command_exists dnf; then
        # Fedora
        sudo dnf install -y "$package"
    elif command_exists pacman; then
        # Arch Linux
        sudo pacman -S --noconfirm "$package"
    else
        log_error "No supported package manager found (tried: brew, apt-get, yum, dnf, pacman)"
        log_error "Please install $package manually"
        return 1
    fi
}

# Install basic system tools
install_system_tools() {
    log_info "Installing basic system tools"
    
    local tools=("curl" "wget" "git" "jq" "unzip")
    
    for tool in "${tools[@]}"; do
        if ! command_exists "$tool"; then
            log_info "Installing $tool"
            install_package "$tool"
            log_success "$tool installed"
        else
            log_success "$tool already installed"
        fi
    done
}

# Install kubectl
install_kubectl() {
    if command_exists kubectl; then
        log_success "kubectl already installed ($(kubectl version --client --short 2>/dev/null || echo 'version unknown'))"
        return 0
    fi

    log_info "Installing kubectl"

    # Detect OS and architecture
    local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local ARCH=$(uname -m)

    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; return 1 ;;
    esac

    # Get latest stable version with error handling
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    if [[ -z "$KUBECTL_VERSION" ]]; then
        log_error "Failed to fetch kubectl version"
        return 1
    fi

    # Download and install kubectl with retry logic
    local KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
    log_info "kubectl download URL: $KUBECTL_URL"

    for attempt in 1 2 3; do
        log_info "Download attempt $attempt/3..."
        log_info "Downloading from: $KUBECTL_URL"
        if curl -L --connect-timeout 30 --max-time 300 -o kubectl "$KUBECTL_URL" -w "HTTP Status: %{http_code}, Download size: %{size_download} bytes\n"; then
            if [[ -f kubectl && -s kubectl ]]; then
                chmod +x kubectl
                if sudo mv kubectl /usr/local/bin/; then
                    log_success "kubectl successfully installed to /usr/local/bin/"
                    break
                else
                    log_error "Failed to move kubectl to /usr/local/bin/"
                    return 1
                fi
            else
                log_error "Downloaded kubectl file is empty or missing"
                rm -f kubectl
                [ $attempt -eq 3 ] && { log_error "Failed to download kubectl after 3 attempts"; return 1; }
            fi
        else
            log_warning "Download attempt $attempt failed"
            [ $attempt -eq 3 ] && { log_error "Failed to download kubectl after 3 attempts"; return 1; }
            sleep 2
        fi
    done

    log_success "kubectl ${KUBECTL_VERSION} installed"
}

# Install Flux CLI
install_flux() {
    if command_exists flux; then
        log_success "Flux CLI already installed ($(flux version --client 2>/dev/null | grep 'flux version' || echo 'version unknown'))"
        return 0
    fi
    
    log_info "Installing Flux CLI"

    # Install Flux using official script with error handling
    log_info "Downloading Flux installation script..."
    if curl -s https://fluxcd.io/install.sh | sudo bash; then
        log_success "Flux CLI installed successfully"
    else
        log_error "Failed to install Flux CLI - check network connectivity and permissions"
        return 1
    fi
    
}

# Install Helm
install_helm() {
    if command_exists helm; then
        log_success "Helm already installed ($(helm version --short 2>/dev/null || echo 'version unknown'))"
        return 0
    fi

    log_info "Installing Helm"

    # Install Helm using official script with retry logic
    for attempt in 1 2 3; do
        log_info "Download attempt $attempt/3..."
        log_info "Downloading Helm installation script..."
        if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; then
            break
        else
            log_warning "Download attempt $attempt failed"
            [ $attempt -eq 3 ] && { log_error "Failed to install helm after 3 attempts"; return 1; }
            sleep 2
        fi
    done

    log_success "Helm installed"
}

# SOPS removed - using zero-secrets architecture with External Secrets

# Install Terraform
install_terraform() {
    if command_exists terraform; then
        log_success "Terraform already installed ($(terraform version -json 2>/dev/null | jq -r .terraform_version || echo 'version unknown'))"
        return 0
    fi

    log_info "Installing Terraform"

    local TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.6.6}"
    local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local ARCH=$(uname -m)

    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; return 1 ;;
    esac

    # Download and install Terraform with retry logic
    local TERRAFORM_ZIP="terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip"
    local TERRAFORM_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${TERRAFORM_ZIP}"
    log_info "terraform download URL: $TERRAFORM_URL"

    for attempt in 1 2 3; do
        log_info "Download attempt $attempt/3..."
        log_info "Downloading from: $TERRAFORM_URL"
        if curl -L --connect-timeout 30 --max-time 180 -o "$TERRAFORM_ZIP" "$TERRAFORM_URL" -w "HTTP Status: %{http_code}, Download size: %{size_download} bytes\n"; then
            if [[ -f "$TERRAFORM_ZIP" && -s "$TERRAFORM_ZIP" ]]; then
                if unzip "$TERRAFORM_ZIP"; then
                    if [[ -f terraform && -s terraform ]]; then
                        chmod +x terraform
                        if sudo mv terraform /usr/local/bin/; then
                            log_success "terraform successfully installed to /usr/local/bin/"
                            rm -f "$TERRAFORM_ZIP"
                            break
                        else
                            log_error "Failed to move terraform to /usr/local/bin/"
                            return 1
                        fi
                    else
                        log_error "Extracted terraform binary is empty or missing"
                        rm -f terraform "$TERRAFORM_ZIP"
                        [ $attempt -eq 3 ] && { log_error "Failed to download terraform after 3 attempts"; return 1; }
                    fi
                else
                    log_error "Failed to unzip $TERRAFORM_ZIP"
                    rm -f "$TERRAFORM_ZIP"
                    [ $attempt -eq 3 ] && { log_error "Failed to download terraform after 3 attempts"; return 1; }
                fi
            else
                log_error "Downloaded terraform zip file is empty or missing"
                rm -f "$TERRAFORM_ZIP"
                [ $attempt -eq 3 ] && { log_error "Failed to download terraform after 3 attempts"; return 1; }
            fi
        else
            log_warning "Download attempt $attempt failed"
            [ $attempt -eq 3 ] && { log_error "Failed to download terraform after 3 attempts"; return 1; }
            sleep 2
        fi
    done

    log_success "Terraform ${TERRAFORM_VERSION} installed"
}

# Install Vault CLI (optional, for debugging)
install_vault_cli() {
    if command_exists vault; then
        log_success "Vault CLI already installed ($(vault version 2>/dev/null | head -1 || echo 'version unknown'))"
        return 0
    fi
    
    log_info "Installing Vault CLI"

    local VAULT_VERSION="${VAULT_VERSION:-1.15.2}"
    local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local ARCH=$(uname -m)

    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; return 1 ;;
    esac

    # Download and install Vault CLI
    local VAULT_ZIP="vault_${VAULT_VERSION}_${OS}_${ARCH}.zip"
    curl -LO "https://releases.hashicorp.com/vault/${VAULT_VERSION}/${VAULT_ZIP}"
    unzip "$VAULT_ZIP"
    chmod +x vault
    sudo mv vault /usr/local/bin/
    rm -f "$VAULT_ZIP"
    
    log_success "Vault CLI ${VAULT_VERSION} installed"
}

# Age removed - not needed for zero-secrets architecture

# Verify installations
verify_tools() {
    log_info "Verifying tool installations"
    
    local tools=("kubectl" "flux" "helm" "terraform" "jq" "curl" "git")
    local failed_tools=()
    
    for tool in "${tools[@]}"; do
        if command_exists "$tool"; then
            local version=""
            case "$tool" in
                kubectl) version=$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo "unknown") ;;
                flux) version=$(flux version --client 2>/dev/null | grep 'flux version' | cut -d' ' -f3 || echo "unknown") ;;
                terraform) version=$(terraform version -json 2>/dev/null | jq -r .terraform_version || echo "unknown") ;;
                vault) version=$(vault version 2>/dev/null | head -1 | cut -d' ' -f2 || echo "unknown") ;;
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
    print_banner "🔧 Bootstrap Tool Installation" "Installing enterprise platform tools"
    
    # Check if running as root (some tools need sudo)
    if [ "$EUID" -eq 0 ]; then
        log_warning "Running as root. Some installations may behave differently."
    fi
    
    # Install tools in order
    install_system_tools
    install_kubectl
    install_helm
    install_flux
    install_terraform
    install_vault_cli  # Optional
    
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
validate_tools() {
    log_info "🔍 Tool Installation Validation Report"
    echo ""

    # System information
    log_info "📋 System Information:"
    log_info "  • OS: $(uname -s)"
    log_info "  • Architecture: $(uname -m)"
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

        if command_exists "$tool"; then
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
        if ! command_exists "$tool"; then
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
    if command_exists brew; then
        log_success "  ✅ Homebrew (macOS): $(brew --version | head -1)"
    elif command_exists apt-get; then
        log_success "  ✅ apt-get (Ubuntu/Debian): available"
    elif command_exists yum; then
        log_success "  ✅ yum (CentOS/RHEL): available"
    elif command_exists dnf; then
        log_success "  ✅ dnf (Fedora): available"
    elif command_exists pacman; then
        log_success "  ✅ pacman (Arch Linux): available"
    else
        log_error "  ❌ No supported package manager found"
    fi

    echo ""
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --validate)
                validate_tools
                exit 0
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --validate    Show current tool status and system information"
                echo "  --help, -h    Show this help message"
                echo ""
                echo "Environment Variables:"
                echo "  LOG_LEVEL     Set logging level (ERROR|WARN|INFO|DEBUG|TRACE)"
                echo "  USE_LOCAL_IMPORTS=true    Use local filesystem instead of remote imports"
                echo "  DEBUG_IMPORTS=true        Show import resolution details"
                echo ""
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
        shift
    done
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    parse_args "$@"
    main
fi