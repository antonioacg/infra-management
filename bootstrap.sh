#!/bin/bash
set -e

# Zero-Secrets Bootstrap Orchestrator
# Coordinates deployment across infra-management, deployments, and infra repositories

# Parse arguments
GITHUB_TOKEN="$1"
SOPS_AGE_KEY="$2"
CLOUDFLARE_TUNNEL_TOKEN="$3"

# Validate arguments
if [ -z "$GITHUB_TOKEN" ] || [ -z "$SOPS_AGE_KEY" ] || [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    echo "Usage: $0 <github_token> <sops_age_key> <cloudflare_tunnel_token>"
    echo ""
    echo "Example:"
    echo "  curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \\"
    echo "    bash -s \"ghp_xxx\" \"AGE-SECRET-KEY-xxx\" \"eyJhxxx\""
    exit 1
fi

# Configuration - can be overridden via repositories.yaml
DEPLOYMENTS_REPO="${DEPLOYMENTS_REPO:-https://github.com/antonioacg/deployments.git}"
INFRA_REPO="${INFRA_REPO:-https://github.com/antonioacg/infra.git}"
WORKSPACE="${WORKSPACE:-/tmp/bootstrap-workspace-$(date +%s)}"
BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-600}"

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

cleanup() {
    log_info "Cleaning up workspace: $WORKSPACE"
    rm -rf "$WORKSPACE"
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
}

# Set trap for cleanup on exit
trap cleanup EXIT

main() {
    echo "🚀 Starting Zero-Secrets Bootstrap Orchestrator"
    echo "📁 Repository: infra-management"
    echo "🌐 Deployments: $DEPLOYMENTS_REPO"  
    echo "🏗️  Infrastructure: $INFRA_REPO"
    echo ""

    # Create workspace
    log_info "Creating workspace: $WORKSPACE"
    mkdir -p "$WORKSPACE"
    cd "$WORKSPACE"

    # Phase 1: Install k3s
    log_info "Phase 1: Installing k3s Kubernetes cluster"
    if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
        log_warning "Kubernetes cluster already running, skipping k3s installation"
    else
        curl -sfL https://get.k3s.io | sh -
        sudo chmod 644 /etc/rancher/k3s/k3s.yaml
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        log_success "k3s installed successfully"
    fi

    # Phase 2: Setup environment
    log_info "Phase 2: Setting up environment"
    # Create temporary SOPS key file (will be cleaned up automatically)
    TEMP_SOPS_DIR="$WORKSPACE/.sops"
    mkdir -p "$TEMP_SOPS_DIR"
    echo "$SOPS_AGE_KEY" > "$TEMP_SOPS_DIR/keys.txt"
    chmod 600 "$TEMP_SOPS_DIR/keys.txt"
    export SOPS_AGE_KEY_FILE="$TEMP_SOPS_DIR/keys.txt"
    export GITHUB_TOKEN="$GITHUB_TOKEN"
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    log_success "Environment configured (temporary SOPS key in workspace)"

    # Phase 3: Deploy GitOps stack
    log_info "Phase 3: Deploying GitOps stack from deployments repository"
    git clone "$DEPLOYMENTS_REPO" deployments
    cd deployments
    
    # Install required tools if not present
    if ! command -v flux >/dev/null 2>&1; then
        log_info "Installing Flux CLI"
        curl -s https://fluxcd.io/install.sh | sudo bash
    fi
    
    if ! command -v sops >/dev/null 2>&1; then
        log_info "Installing SOPS"
        SOPS_VERSION="v3.8.1"
        curl -LO "https://github.com/mozilla/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
        sudo mv "sops-${SOPS_VERSION}.linux.amd64" /usr/local/bin/sops
        sudo chmod +x /usr/local/bin/sops
    fi

    # Run deployment installation
    if [ -f "./install.sh" ]; then
        ./install.sh
        log_success "GitOps stack deployed"
    else
        log_error "install.sh not found in deployments repository"
        exit 1
    fi
    
    cd "$WORKSPACE"

    # Phase 4: Wait for Vault
    log_info "Phase 4: Waiting for Vault to be ready"
    timeout "$BOOTSTRAP_TIMEOUT" bash -c '
        until kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath="{.items[?(@.status.phase==\"Running\")].metadata.name}" | grep -q vault; do
            echo "Waiting for Vault pod..."
            sleep 10
        done
    '
    
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s
    log_success "Vault is ready"

    # Phase 5: Infrastructure and secrets management
    log_info "Phase 5: Setting up infrastructure and populating secrets"
    git clone "$INFRA_REPO" infra
    cd infra

    # Navigate to Terraform environment
    if [ -d "envs/prod" ]; then
        cd envs/prod
    else
        log_error "Terraform environment directory not found (expected: envs/prod)"
        exit 1
    fi

    # Install Terraform if not present
    if ! command -v terraform >/dev/null 2>&1; then
        log_info "Installing Terraform"
        TERRAFORM_VERSION="1.6.6"
        curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
        unzip "terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
        sudo mv terraform /usr/local/bin/
        rm "terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    fi

    # Setup Vault connection via port-forward
    log_info "Setting up Vault connection"
    kubectl port-forward -n vault svc/vault 8200:8200 &
    VAULT_PF_PID=$!
    sleep 5

    # Configure Vault environment
    export VAULT_ADDR="http://localhost:8200"
    
    # Get Vault token (try multiple approaches for compatibility)
    if kubectl get secret -n vault vault-init-keys >/dev/null 2>&1; then
        export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
    else
        log_error "Cannot retrieve Vault token. Ensure Vault initialization completed successfully."
        exit 1
    fi

    # Set Terraform variables
    export TF_VAR_cloudflare_tunnel_token="$CLOUDFLARE_TUNNEL_TOKEN"
    
    # Run Terraform
    log_info "Initializing Terraform"
    terraform init
    
    log_info "Applying Terraform configuration"  
    terraform plan -var-file=terraform.tfvars 2>/dev/null || terraform plan
    terraform apply -auto-approve
    
    # Cleanup port-forward
    kill $VAULT_PF_PID 2>/dev/null || true
    log_success "Infrastructure and secrets configured"

    cd "$WORKSPACE"

    # Phase 6: Verification
    log_info "Phase 6: Running post-deployment verification"
    
    echo "🔍 Kubernetes Pods:"
    kubectl get pods -A | grep -E "(vault|cloudflared|external-secrets|flux)" || true
    
    echo ""
    echo "🔍 Flux Status:"
    flux get all --all-namespaces
    
    echo ""  
    echo "🔍 External Secrets:"
    kubectl get externalsecrets -A 2>/dev/null || log_warning "External Secrets not yet deployed"
    
    echo ""
    echo "🔍 Vault Status:"
    kubectl exec -n vault vault-0 -- vault status 2>/dev/null || log_warning "Cannot check Vault status"

    # Final success message
    echo ""
    log_success "🎉 Bootstrap completed successfully!"
    echo ""
    echo "Your zero-secrets Kubernetes infrastructure is ready:"
    echo "  ✅ GitOps deployment pipeline (Flux)"
    echo "  ✅ Centralized secret management (Vault)"  
    echo "  ✅ Automatic secret synchronization (External Secrets Operator)"
    echo "  ✅ Secure tunnel access (Cloudflared)"
    echo ""
    echo "Next steps:"
    echo "  • Monitor deployment: kubectl get pods -A"
    echo "  • Check GitOps status: flux get all --all-namespaces"
    echo "  • View application logs: kubectl logs -n <namespace> <pod>"
    echo "  • Access services via your Cloudflare tunnel"
}

# Execute main function
main "$@"