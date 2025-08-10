#!/bin/bash
# Tool Installation Helper for Bootstrap Process

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install a package using appropriate package manager
install_package() {
    local package="$1"
    
    if command_exists apt-get; then
        sudo apt-get update -qq
        sudo apt-get install -y "$package"
    elif command_exists yum; then
        sudo yum install -y "$package"
    elif command_exists dnf; then
        sudo dnf install -y "$package"
    elif command_exists pacman; then
        sudo pacman -S --noconfirm "$package"
    else
        log_error "No supported package manager found"
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
    
    # Get latest stable version
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    
    # Download and install kubectl
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    
    log_success "kubectl ${KUBECTL_VERSION} installed"
}

# Install Flux CLI
install_flux() {
    if command_exists flux; then
        log_success "Flux CLI already installed ($(flux version --client 2>/dev/null | grep 'flux version' || echo 'version unknown'))"
        return 0
    fi
    
    log_info "Installing Flux CLI"
    
    # Install Flux using official script
    curl -s https://fluxcd.io/install.sh | sudo bash
    
    log_success "Flux CLI installed"
}

# Install SOPS
install_sops() {
    if command_exists sops; then
        log_success "SOPS already installed ($(sops --version 2>/dev/null || echo 'version unknown'))"
        return 0
    fi
    
    log_info "Installing SOPS"
    
    local SOPS_VERSION="${SOPS_VERSION:-v3.8.1}"
    local ARCH=$(uname -m)
    
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; return 1 ;;
    esac
    
    # Download and install SOPS
    curl -LO "https://github.com/mozilla/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${ARCH}"
    chmod +x "sops-${SOPS_VERSION}.linux.${ARCH}"
    sudo mv "sops-${SOPS_VERSION}.linux.${ARCH}" /usr/local/bin/sops
    
    log_success "SOPS ${SOPS_VERSION} installed"
}

# Install Terraform
install_terraform() {
    if command_exists terraform; then
        log_success "Terraform already installed ($(terraform version -json 2>/dev/null | jq -r .terraform_version || echo 'version unknown'))"
        return 0
    fi
    
    log_info "Installing Terraform"
    
    local TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.6.6}"
    local ARCH=$(uname -m)
    
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; return 1 ;;
    esac
    
    # Download and install Terraform
    local TERRAFORM_ZIP="terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip"
    curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${TERRAFORM_ZIP}"
    unzip "$TERRAFORM_ZIP"
    chmod +x terraform
    sudo mv terraform /usr/local/bin/
    rm -f "$TERRAFORM_ZIP"
    
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
    local ARCH=$(uname -m)
    
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; return 1 ;;
    esac
    
    # Download and install Vault CLI
    local VAULT_ZIP="vault_${VAULT_VERSION}_linux_${ARCH}.zip"
    curl -LO "https://releases.hashicorp.com/vault/${VAULT_VERSION}/${VAULT_ZIP}"
    unzip "$VAULT_ZIP"
    chmod +x vault
    sudo mv vault /usr/local/bin/
    rm -f "$VAULT_ZIP"
    
    log_success "Vault CLI ${VAULT_VERSION} installed"
}

# Install Age (for SOPS)
install_age() {
    if command_exists age; then
        log_success "Age already installed ($(age --version 2>/dev/null || echo 'version unknown'))"
        return 0
    fi
    
    log_info "Installing Age"
    
    local AGE_VERSION="${AGE_VERSION:-v1.1.1}"
    local ARCH=$(uname -m)
    
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; return 1 ;;
    esac
    
    # Download and install Age
    local AGE_TAR="age-${AGE_VERSION}-linux-${ARCH}.tar.gz"
    curl -LO "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${AGE_TAR}"
    tar -xzf "$AGE_TAR"
    sudo mv "age/age" /usr/local/bin/
    sudo mv "age/age-keygen" /usr/local/bin/
    rm -rf age "$AGE_TAR"
    
    log_success "Age ${AGE_VERSION} installed"
}

# Verify installations
verify_tools() {
    log_info "Verifying tool installations"
    
    local tools=("kubectl" "flux" "sops" "terraform" "age" "jq" "curl" "git")
    local failed_tools=()
    
    for tool in "${tools[@]}"; do
        if command_exists "$tool"; then
            local version=""
            case "$tool" in
                kubectl) version=$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo "unknown") ;;
                flux) version=$(flux version --client 2>/dev/null | grep 'flux version' | cut -d' ' -f3 || echo "unknown") ;;
                sops) version=$(sops --version 2>/dev/null | cut -d' ' -f2 || echo "unknown") ;;
                terraform) version=$(terraform version -json 2>/dev/null | jq -r .terraform_version || echo "unknown") ;;
                age) version=$(age --version 2>/dev/null | cut -d' ' -f2 || echo "unknown") ;;
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
    echo "🔧 Bootstrap Tool Installation Script"
    echo "===================================="
    echo ""
    
    # Check if running as root (some tools need sudo)
    if [ "$EUID" -eq 0 ]; then
        log_warning "Running as root. Some installations may behave differently."
    fi
    
    # Install tools in order
    install_system_tools
    install_kubectl
    install_flux  
    install_sops
    install_age
    install_terraform
    install_vault_cli  # Optional
    
    echo ""
    verify_tools
    
    echo ""
    log_success "🎉 Tool installation completed!"
    echo ""
    echo "Installed tools:"
    echo "  • kubectl - Kubernetes CLI"
    echo "  • flux - GitOps CLI"  
    echo "  • sops - Secret encryption"
    echo "  • age - Encryption tool"
    echo "  • terraform - Infrastructure as code"
    echo "  • vault - Secret management CLI (optional)"
    echo ""
    echo "You can now run the bootstrap script!"
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi