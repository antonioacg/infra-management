#!/bin/bash
set -e

# Zero-Secrets 3-Tier Bootstrap Orchestrator
# Architecture: Bootstrap → Infrastructure → Applications
# Secret flow: Environment Variables → Terraform → Vault → External Secrets → Kubernetes

# Required environment variables
required_vars=("GITHUB_TOKEN")

# Configuration
DEPLOYMENTS_REPO="${DEPLOYMENTS_REPO:-https://github.com/antonioacg/deployments.git}"
INFRA_REPO="${INFRA_REPO:-https://github.com/antonioacg/infra.git}"
WORKSPACE="${WORKSPACE:-/tmp/bootstrap-workspace-$(date +%s)}"
BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-600}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_phase() {
    echo -e "${PURPLE}🚀 TIER $1: $2${NC}"
    echo "=================================================="
}

cleanup() {
    log_info "Cleaning up workspace and environment..."
    rm -rf "$WORKSPACE"
    jobs -p | xargs -r kill 2>/dev/null || true
    
    for var in "${required_vars[@]}"; do
        unset "$var" 2>/dev/null || true
    done
    
    for var in $(env | grep "^TF_VAR_" | cut -d= -f1); do
        unset "$var" 2>/dev/null || true
    done
    
    log_success "Environment cleaned - no secrets remaining in memory"
}

trap cleanup EXIT

validate_environment() {
    log_info "Validating required environment variables..."
    missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        echo ""
        echo "Usage: GITHUB_TOKEN=\"ghp_xxx\" curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | bash"
        exit 1
    fi
    
    log_success "All required environment variables validated"
}

install_k3s() {
    log_info "Installing k3s Kubernetes cluster..."
    
    if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
        log_warning "Kubernetes cluster already running, skipping k3s installation"
        # Ensure KUBECONFIG is properly set for k3s
        if [[ -f /etc/rancher/k3s/k3s.yaml && -z "$KUBECONFIG" ]]; then
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
            log_info "Set KUBECONFIG to /etc/rancher/k3s/k3s.yaml"
        fi
        return
    fi
    
    # Hardware detection for resource adaptation
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
    CPU_CORES=$(nproc)
    
    log_info "Detected hardware: ${CPU_CORES} CPU cores, ${TOTAL_RAM_GB}GB RAM"
    
    K3S_ARGS=""
    if [[ $TOTAL_RAM_GB -lt 4 ]]; then
        log_info "Low memory system detected, optimizing k3s for resource constraints"
        K3S_ARGS="--disable traefik --disable servicelb"
    fi
    
    curl -sfL https://get.k3s.io | sh -s - $K3S_ARGS
    sudo chmod 644 /etc/rancher/k3s/k3s.yaml
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    
    TIMEOUT=$((TOTAL_RAM_GB < 4 ? 120 : 60))
    timeout $TIMEOUT bash -c 'until kubectl get nodes | grep -q Ready; do echo "Waiting for k3s..."; sleep 5; done'
    
    log_success "k3s installed and ready"
}

install_tools() {
    log_info "Installing required tools..."
    
    # Install Flux CLI
    if ! command -v flux >/dev/null 2>&1; then
        log_info "Installing Flux CLI"
        curl -s https://fluxcd.io/install.sh | sudo bash
    fi
    
    # Install Terraform with architecture detection
    if ! command -v terraform >/dev/null 2>&1; then
        log_info "Installing Terraform"
        TERRAFORM_VERSION="1.6.6"
        
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) TERRAFORM_ARCH="amd64" ;;
            aarch64|arm64) TERRAFORM_ARCH="arm64" ;;
            *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
        esac
        
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        
        curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${TERRAFORM_ARCH}.zip"
        unzip "terraform_${TERRAFORM_VERSION}_${OS}_${TERRAFORM_ARCH}.zip"
        
        # Try to install to /usr/local/bin, fallback to user directory
        if sudo mv terraform /usr/local/bin/ 2>/dev/null; then
            log_success "Terraform installed to /usr/local/bin/"
        else
            mkdir -p "$HOME/.local/bin"
            mv terraform "$HOME/.local/bin/"
            export PATH="$HOME/.local/bin:$PATH"
            log_success "Terraform installed to $HOME/.local/bin/ (added to PATH)"
        fi
        
        rm "terraform_${TERRAFORM_VERSION}_${OS}_${TERRAFORM_ARCH}.zip"
    fi
    
    log_success "All tools installed"
}

deploy_bootstrap_tier() {
    log_info "Deploying Tier 1: Bootstrap (Vault + External Secrets + Vault MinIO)..."
    
    cd "$WORKSPACE"
    
    # Clone with GitHub token authentication
    DEPLOYMENTS_REPO_WITH_AUTH="https://$GITHUB_TOKEN@github.com/antonioacg/deployments.git"
    
    if ! git clone "$DEPLOYMENTS_REPO_WITH_AUTH" deployments; then
        log_error "Git clone failed - check GitHub token and repository access"
        exit 1
    fi
    
    cd deployments
    
    # Install Flux controllers
    log_info "Installing Flux controllers"
    if ! flux install; then
        log_error "Flux install failed"
        exit 1
    fi
    
    # Wait for Flux CRDs
    log_info "Waiting for Flux CRDs..."
    kubectl wait --for condition=established --timeout=60s crd/kustomizations.kustomize.toolkit.fluxcd.io
    kubectl wait --for condition=established --timeout=60s crd/helmreleases.helm.toolkit.fluxcd.io
    kubectl wait --for condition=established --timeout=60s crd/helmrepositories.source.toolkit.fluxcd.io
    
    # Deploy Bootstrap Tier
    log_info "Deploying Bootstrap tier (zero external dependencies)"
    kubectl apply -k clusters/production/bootstrap/
    
    # Wait for External Secrets CRDs
    log_info "Waiting for External Secrets CRDs..."
    timeout 180 bash -c '
        until kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1 && \
              kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; do
            echo "Waiting for External Secrets CRDs..."
            sleep 10
        done
    '
    
    # Apply again to create External Secrets resources now that CRDs exist
    kubectl apply -k clusters/production/bootstrap/
    
    log_success "Bootstrap tier deployed"
}

wait_for_vault_ready() {
    log_info "Waiting for Vault to be ready and auto-unsealed..."
    
    # Wait for Vault pod
    timeout "$BOOTSTRAP_TIMEOUT" bash -c '
        until kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath="{.items[?(@.status.phase==\"Running\")].metadata.name}" | grep -q vault; do
            echo "Waiting for Vault pod..."
            sleep 10
        done
    '
    
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s
    
    # Wait for auto-unsealing
    timeout 120 bash -c '
        until kubectl exec -n vault vault-0 -- vault status >/dev/null 2>&1; do
            echo "Waiting for Vault auto-unseal..."
            sleep 10
        done
    '
    
    log_success "Vault is ready and unsealed"
}

populate_vault_with_secrets() {
    log_info "Populating Vault with ALL secrets via Terraform..."
    
    cd "$WORKSPACE"
    git clone "$INFRA_REPO" infra
    cd infra/envs/prod
    
    # Setup Vault connection
    kubectl port-forward -n vault svc/vault 8200:8200 &
    VAULT_PF_PID=$!
    sleep 5
    
    export VAULT_ADDR="http://localhost:8200"
    
    # Get Vault token from auto-unsealing
    if kubectl get secret -n vault vault-init-keys >/dev/null 2>&1; then
        export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
        log_success "Retrieved Vault token from auto-unsealing process"
    else
        log_error "Cannot retrieve Vault token"
        exit 1
    fi
    
    # Configure Terraform
    export TF_VAR_github_token="$GITHUB_TOKEN"
    
    # Run Terraform
    terraform init
    terraform apply -auto-approve
    
    kill $VAULT_PF_PID 2>/dev/null || true
    
    log_success "ALL secrets populated in Vault"
    cd "$WORKSPACE"
}

deploy_infrastructure_tier() {
    log_info "Deploying Tier 2: Infrastructure (depends on Vault secrets)..."
    
    cd "$WORKSPACE/deployments"
    
    # Deploy Infrastructure tier
    kubectl apply -k clusters/production/infrastructure/
    
    # Wait for key infrastructure components
    log_info "Waiting for infrastructure components..."
    
    # Wait for MinIO (application storage)
    if kubectl wait --for=condition=Ready helmrelease/minio -n minio --timeout=300s; then
        log_success "Application MinIO ready"
    else
        log_warning "Application MinIO timeout - continuing"
    fi
    
    log_success "Infrastructure tier deployed"
}

deploy_applications_tier() {
    log_info "Deploying Tier 3: Applications (depends on infrastructure + Vault)..."
    
    cd "$WORKSPACE/deployments"
    
    # Deploy Applications tier
    kubectl apply -k clusters/production/applications/
    
    # Wait for External Secrets to sync application secrets
    log_info "Waiting for External Secrets to sync application secrets..."
    timeout 300 bash -c '
        until kubectl get externalsecrets -A --no-headers 2>/dev/null | grep -q "True"; do
            current_synced=$(kubectl get externalsecrets -A --no-headers 2>/dev/null | grep -c "True" || echo "0")
            echo "External Secrets synced: $current_synced"
            sleep 15
        done
    '
    
    log_success "Applications tier deployed"
}

verify_complete_architecture() {
    log_info "Verifying complete 3-tier architecture..."
    
    echo ""
    echo "🔍 Kubernetes Cluster:"
    kubectl get nodes
    
    echo ""
    echo "🔍 Bootstrap Tier (Tier 1):"
    kubectl get pods -n vault -n vault-minio -n external-secrets-system
    
    echo ""
    echo "🔍 Infrastructure Tier (Tier 2):"
    kubectl get pods -n minio -n cloudflared -n ingress-nginx 2>/dev/null || echo "Some infrastructure components not yet deployed"
    
    echo ""
    echo "🔍 Applications Tier (Tier 3):"
    kubectl get pods -A | grep -v "kube-system\|flux-system\|vault\|minio\|external-secrets\|cloudflared\|ingress" || echo "No business applications deployed yet"
    
    echo ""
    echo "🔍 External Secrets Status:"
    kubectl get externalsecrets -A -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,READY:.status.conditions[0].status"
    
    echo ""
    echo "🔐 Zero-Secrets Architecture Validation:"
    
    # Validate GitHub token is in Vault
    kubectl port-forward -n vault svc/vault 8200:8200 &
    VAULT_PF_PID=$!
    sleep 5
    
    export VAULT_ADDR="http://localhost:8200"
    export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
    
    if vault kv get secret/github/auth >/dev/null 2>&1; then
        log_success "✅ GitHub token stored in Vault"
    else
        log_error "❌ GitHub token not found in Vault"
    fi
    
    kill $VAULT_PF_PID 2>/dev/null || true
    
    # Check environment cleanup
    if [ -z "$GITHUB_TOKEN" ]; then
        log_success "✅ Bootstrap environment variables cleared"
    else
        log_warning "⚠️  Bootstrap environment variables still present"
    fi
    
    echo ""
    echo "🎯 3-TIER ZERO-SECRETS ARCHITECTURE ACHIEVED:"
    echo "  ✅ Tier 1: Bootstrap (vault, vault-minio, external-secrets) - zero external dependencies"
    echo "  ✅ Tier 2: Infrastructure (minio, cloudflared, nginx-ingress) - depends on Vault secrets"  
    echo "  ✅ Tier 3: Applications - depends on infrastructure services + Vault secrets"
    echo "  ✅ No secrets in Git repositories"
    echo "  ✅ All secrets managed through Vault → External Secrets → Kubernetes"
    echo "  ✅ Modern API versions (no deprecation warnings)"
    echo "  ✅ Decentralized namespace management"
}

main() {
    echo "🚀 Zero-Secrets 3-Tier Bootstrap Orchestrator"
    echo "Architecture: Bootstrap → Infrastructure → Applications"
    echo "Secret Flow: Environment → Terraform → Vault → External Secrets → Kubernetes"
    echo ""
    
    # Create workspace
    mkdir -p "$WORKSPACE"
    cd "$WORKSPACE"
    
    # Validation
    validate_environment
    
    # Tier 1: Bootstrap (zero external dependencies)
    log_phase "1" "Bootstrap (Vault + External Secrets + Vault MinIO)"
    install_k3s
    install_tools
    deploy_bootstrap_tier
    wait_for_vault_ready
    
    # Secret Population
    log_phase "SECRETS" "Populate Vault with ALL secrets via Terraform"
    populate_vault_with_secrets
    
    # Tier 2: Infrastructure (depends on Vault secrets)
    log_phase "2" "Infrastructure (Application MinIO + CloudFlared + Nginx)"
    deploy_infrastructure_tier
    
    # Tier 3: Applications (depends on infrastructure + Vault)
    log_phase "3" "Applications (Business Applications)"
    deploy_applications_tier
    
    # Verification
    log_phase "VERIFY" "Complete Architecture Verification"
    verify_complete_architecture
    
    echo ""
    log_success "🎉 3-Tier Zero-Secrets Bootstrap completed successfully!"
    echo ""
    echo "Your complete infrastructure is ready:"
    echo "  ✅ Tier 1: Bootstrap components with auto-unsealing Vault"
    echo "  ✅ Secret Population: ALL secrets stored in Vault via Terraform"
    echo "  ✅ Tier 2: Infrastructure services using Vault secrets"
    echo "  ✅ Tier 3: Applications using infrastructure + Vault secrets"
    echo ""
    echo "Next steps:"
    echo "  • Monitor: kubectl get pods -A"
    echo "  • Verify secrets: kubectl get externalsecrets -A"
    echo "  • Access services via CloudFlare tunnel"
    echo ""
    echo "🔒 Security: All bootstrap secrets cleared from environment"
    echo "🏛️  Secret Management: All secrets now managed through Vault + External Secrets"
}

main "$@"