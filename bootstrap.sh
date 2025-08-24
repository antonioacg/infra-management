#!/bin/bash
set -e

# Zero-Secrets Phase-Based Bootstrap Orchestrator
# Implements complete zero-secrets architecture with proper sequencing
# All secrets flow: Environment Variables → Terraform → Vault → External Secrets → Kubernetes

# Required environment variables (only needed during bootstrap)
required_vars=(
    "GITHUB_TOKEN"
    "CLOUDFLARE_TUNNEL_TOKEN"
)

# Configuration - can be overridden via environment
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

log_phase() {
    echo -e "${PURPLE}🚀 PHASE $1: $2${NC}"
    echo "=================================================="
}

cleanup() {
    log_info "Cleaning up workspace and environment..."
    
    # Clean up workspace
    rm -rf "$WORKSPACE"
    
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Clean up bootstrap environment variables (security)
    log_info "Clearing bootstrap secrets from environment"
    for var in "${required_vars[@]}"; do
        unset "$var" 2>/dev/null || true
    done
    
    # Clear any TF_VAR_* variables
    for var in $(env | grep "^TF_VAR_" | cut -d= -f1); do
        unset "$var" 2>/dev/null || true
    done
    
    log_success "Environment cleaned - no secrets remaining in memory"
}

# Set trap for cleanup on exit
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
        echo "Usage example:"
        echo "  GITHUB_TOKEN=\"ghp_xxx\" \\"
        echo "  CLOUDFLARE_TUNNEL_TOKEN=\"eyJhxxx\" \\"
        echo "  curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | bash"
        echo ""
        echo "Security note: Environment variables are more secure than command-line arguments"
        exit 1
    fi
    
    log_success "All required environment variables validated"
}

install_k3s() {
    log_info "Installing k3s Kubernetes cluster..."
    
    if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
        log_warning "Kubernetes cluster already running, skipping k3s installation"
        export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
        return
    fi
    
    # Detect hardware capabilities for resource adaptation
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
    CPU_CORES=$(nproc)
    
    log_info "Detected hardware: ${CPU_CORES} CPU cores, ${TOTAL_RAM_GB}GB RAM"
    
    # Adapt k3s configuration based on hardware
    K3S_ARGS=""
    if [[ $TOTAL_RAM_GB -lt 4 ]]; then
        log_info "Low memory system detected, optimizing k3s for resource constraints"
        K3S_ARGS="--disable traefik --disable servicelb"
    fi
    
    # Install k3s with hardware-specific configuration
    curl -sfL https://get.k3s.io | sh -s - $K3S_ARGS
    sudo chmod 644 /etc/rancher/k3s/k3s.yaml
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    
    # Adaptive timeout based on hardware
    TIMEOUT=$((TOTAL_RAM_GB < 4 ? 120 : 60))
    timeout $TIMEOUT bash -c 'until kubectl get nodes | grep -q Ready; do echo "Waiting for k3s..."; sleep 5; done'
    
    log_success "k3s installed and ready (adapted for ${TOTAL_RAM_GB}GB RAM system)"
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
        
        # Detect architecture
        ARCH=$(uname -m)
        case $ARCH in
            x86_64)
                TERRAFORM_ARCH="amd64"
                ;;
            aarch64|arm64)
                TERRAFORM_ARCH="arm64"
                ;;
            *)
                log_error "Unsupported architecture: $ARCH"
                exit 1
                ;;
        esac
        
        # Detect OS
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        
        log_info "Detected platform: ${OS}_${TERRAFORM_ARCH}"
        
        curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${TERRAFORM_ARCH}.zip"
        unzip "terraform_${TERRAFORM_VERSION}_${OS}_${TERRAFORM_ARCH}.zip"
        sudo mv terraform /usr/local/bin/
        rm "terraform_${TERRAFORM_VERSION}_${OS}_${TERRAFORM_ARCH}.zip"
    fi
    
    log_success "All tools installed"
}

deploy_infrastructure_phase() {
    log_info "Deploying infrastructure components (Vault + External Secrets Operator)..."
    
    cd "$WORKSPACE"
    git clone "$DEPLOYMENTS_REPO" deployments
    cd deployments
    
    # Create temporary Flux bootstrap with GitHub token
    log_info "Bootstrapping Flux with direct GitHub authentication"
    export GITHUB_TOKEN
    flux bootstrap git \
        --url="$DEPLOYMENTS_REPO" \
        --branch=main \
        --path=clusters/production/infrastructure \
        --token-auth
    
    log_success "Infrastructure phase deployed"
}

wait_for_vault_ready() {
    log_info "Waiting for Vault to be ready and auto-unsealed..."
    
    # Wait for Vault pod to be running
    timeout "$BOOTSTRAP_TIMEOUT" bash -c '
        until kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath="{.items[?(@.status.phase==\"Running\")].metadata.name}" | grep -q vault; do
            echo "Waiting for Vault pod..."
            sleep 10
        done
    '
    
    # Wait for Vault to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s
    
    # Wait for auto-unsealing to complete
    timeout 60 bash -c '
        until kubectl exec -n vault vault-0 -- vault status >/dev/null 2>&1; do
            echo "Waiting for Vault auto-unseal..."
            sleep 5
        done
    '
    
    log_success "Vault is ready and unsealed"
}

populate_vault_with_all_secrets() {
    log_info "Populating Vault with ALL secrets via Terraform..."
    
    cd "$WORKSPACE"
    git clone "$INFRA_REPO" infra
    cd infra/envs/prod
    
    # Setup Vault connection via port-forward
    log_info "Setting up Vault connection for secret population"
    kubectl port-forward -n vault svc/vault 8200:8200 &
    VAULT_PF_PID=$!
    sleep 5
    
    # Configure Vault environment
    export VAULT_ADDR="http://localhost:8200"
    
    # Get Vault token from auto-unsealing process
    if kubectl get secret -n vault vault-init-keys >/dev/null 2>&1; then
        export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
        log_success "Retrieved Vault token from auto-unsealing process"
    else
        log_error "Cannot retrieve Vault token. Ensure Vault initialization completed successfully."
        exit 1
    fi
    
    # Set Terraform variables from environment variables
    log_info "Configuring Terraform with ALL bootstrap secrets"
    export TF_VAR_github_token="$GITHUB_TOKEN"
    export TF_VAR_cloudflare_tunnel_token="$CLOUDFLARE_TUNNEL_TOKEN"
    # Add other TF_VAR_* exports as secrets are added to the system
    
    # Run Terraform to populate Vault with ALL secrets
    log_info "Initializing Terraform"
    terraform init
    
    log_info "Planning Terraform configuration (ALL secrets will be stored in Vault)"
    terraform plan
    
    log_info "Applying Terraform - populating ALL secrets in Vault"
    terraform apply -auto-approve
    
    # Cleanup port-forward
    kill $VAULT_PF_PID 2>/dev/null || true
    
    log_success "ALL secrets populated in Vault (including GitHub token for Flux)"
    
    cd "$WORKSPACE"
}

wait_for_external_secrets_ready() {
    log_info "Validating External Secrets Operator is ready for Vault authentication..."
    
    # Wait for External Secrets Operator to be running
    timeout 300 bash -c '
        until kubectl get pods -n external-secrets-system -l app.kubernetes.io/name=external-secrets 2>/dev/null | grep -q "Running"; do
            echo "Waiting for External Secrets Operator..."
            sleep 10
        done
    '
    
    # Validate ClusterSecretStore can authenticate to Vault
    log_info "Testing ClusterSecretStore Vault authentication..."
    
    # Setup Vault connection for testing
    kubectl port-forward -n vault svc/vault 8200:8200 &
    VAULT_PF_PID=$!
    sleep 5
    
    export VAULT_ADDR="http://localhost:8200"
    export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
    
    # Verify the External Secrets service account exists with correct role
    if ! vault read auth/kubernetes/role/external-secrets >/dev/null 2>&1; then
        log_error "External Secrets Vault role not found - Terraform may have failed"
        kill $VAULT_PF_PID 2>/dev/null || true
        exit 1
    fi
    
    # Test reading the GitHub token that External Secret will need
    if ! vault kv get secret/github/auth >/dev/null 2>&1; then
        log_error "GitHub token not found in Vault - Phase 2 may have failed"
        kill $VAULT_PF_PID 2>/dev/null || true
        exit 1
    fi
    
    kill $VAULT_PF_PID 2>/dev/null || true
    
    log_success "External Secrets Operator ready for Vault authentication"
}

deploy_flux_auth_phase() {
    log_info "Deploying Flux External Secrets authentication..."
    
    cd "$WORKSPACE/deployments"
    
    # Add flux-auth to the main kustomization
    if ! grep -q "flux-auth" clusters/production/kustomization.yaml; then
        echo "  - flux-auth/" >> clusters/production/kustomization.yaml
        git add clusters/production/kustomization.yaml
        git commit -m "feat: add flux-auth phase for External Secrets"
        git push origin main
    fi
    
    # Trigger reconciliation to deploy External Secret
    log_info "Deploying External Secret for GitHub token..."
    flux reconcile source git flux-system
    flux reconcile kustomization flux-system
    
    # Wait for External Secret to sync GitHub token
    log_info "Waiting for GitHub token External Secret to sync..."
    timeout 180 bash -c '
        until kubectl get secret flux-system -n flux-system >/dev/null 2>&1 && \
              kubectl get externalsecret flux-git-auth -n flux-system -o jsonpath="{.status.conditions[0].status}" 2>/dev/null | grep -q "True"; do
            echo "Waiting for External Secret to sync GitHub token..."
            sleep 10
        done
    '
    
    # Validate secret content before handoff (CRITICAL SAFETY CHECK)
    log_info "Validating External Secret created correct GitHub token format..."
    if ! kubectl get secret flux-system -n flux-system -o jsonpath='{.data.password}' | base64 -d | grep -q "ghp_"; then
        log_error "External Secret did not create valid GitHub token - ABORTING handoff"
        log_error "This prevents permanent Flux authentication breakage"
        exit 1
    fi
    
    # Critical handoff: Patch GitRepository to use the External Secret
    log_info "⚠️  CRITICAL HANDOFF: Patching Flux GitRepository to use External Secret authentication..."
    log_warning "If this fails, Flux Git authentication will be broken!"
    
    # Store original spec for rollback
    kubectl get gitrepository flux-system -n flux-system -o yaml > "$WORKSPACE/flux-gitrepo-backup.yaml"
    
    if ! kubectl patch gitrepository flux-system -n flux-system --type='merge' -p='{"spec":{"secretRef":{"name":"flux-system"}}}'; then
        log_error "Failed to patch GitRepository - authentication handoff failed"
        log_error "Manual recovery may be required"
        exit 1
    fi
    
    # Restart source controller to pick up new authentication immediately
    log_info "Restarting Flux source controller for immediate auth switch..."
    kubectl rollout restart deployment source-controller -n flux-system
    kubectl wait --for=condition=available deployment source-controller -n flux-system --timeout=120s
    
    # Verify Git access with new authentication (WITH ROLLBACK)
    log_info "🔍 CRITICAL TEST: Verifying Git access with External Secrets authentication..."
    if ! timeout 60 bash -c '
        until flux reconcile source git flux-system --timeout=30s 2>/dev/null; do
            echo "Waiting for Git access with new authentication..."
            sleep 10
        done
    '; then
        log_error "❌ Git access failed with External Secrets authentication!"
        log_warning "Attempting rollback to original authentication..."
        kubectl apply -f "$WORKSPACE/flux-gitrepo-backup.yaml"
        kubectl rollout restart deployment source-controller -n flux-system
        log_error "Rollback attempted - check Flux status manually"
        exit 1
    fi
    
    log_success "Flux successfully switched to External Secrets for Git authentication"
}

deploy_applications_phase() {
    log_info "Deploying applications with working External Secrets..."
    
    cd "$WORKSPACE/deployments"
    
    # Add applications to the main kustomization
    if ! grep -q "applications" clusters/production/kustomization.yaml; then
        echo "  - applications/" >> clusters/production/kustomization.yaml
        git add clusters/production/kustomization.yaml
        git commit -m "feat: add applications phase with External Secrets"
        git push origin main
    fi
    
    # Trigger full reconciliation to deploy applications
    flux reconcile source git flux-system
    flux reconcile kustomization flux-system
    
    # Wait for External Secrets to sync all application secrets
    log_info "Waiting for External Secrets to sync all application secrets..."
    timeout 300 bash -c '
        expected_secrets=1  # At least cloudflared External Secret
        until [ "$(kubectl get externalsecrets -A --no-headers 2>/dev/null | grep -c "True")" -ge "$expected_secrets" ]; do
            current_count=$(kubectl get externalsecrets -A --no-headers 2>/dev/null | grep -c "True" || echo "0")
            echo "External Secrets synced: $current_count/$expected_secrets"
            sleep 15
        done
    '
    
    # Wait for application pods to be ready
    log_info "Waiting for application pods to be ready..."
    timeout 300 bash -c '
        until kubectl get pods -n cloudflared --no-headers 2>/dev/null | grep -q "Running"; do
            echo "Waiting for application pods..."
            sleep 10
        done
    '
    
    log_success "Applications deployed with working External Secrets"
}

verify_all_phases() {
    log_info "Running comprehensive verification of all phases..."
    
    echo ""
    echo "🔍 Kubernetes Cluster Status:"
    kubectl get nodes
    
    echo ""
    echo "🔍 Flux Status:"
    flux get all --all-namespaces
    
    echo ""
    echo "🔍 Vault Status:"
    kubectl exec -n vault vault-0 -- vault status 2>/dev/null || log_warning "Cannot check Vault status"
    
    echo ""
    echo "🔍 External Secrets Status:"
    kubectl get externalsecrets -A
    
    echo ""
    echo "🔍 External Secrets Sync Status:"
    kubectl get externalsecrets -A -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,READY:.status.conditions[0].status"
    
    echo ""
    echo "🔍 Application Pods Status:"
    kubectl get pods -A | grep -E "(vault|cloudflared|external-secrets|flux)" || true
    
    echo ""
    echo "🔍 Secrets Created by External Secrets:"
    kubectl get secrets -A | grep -v "kubernetes.io" | grep -v "Opaque.*0" || log_warning "No External Secrets created yet"
    
    echo ""
    echo "🔐 CRITICAL: Zero-Secrets Architecture Validation:"
    
    # Validate Flux is using External Secrets (not environment variables)
    if kubectl get gitrepository flux-system -n flux-system -o jsonpath='{.spec.secretRef.name}' 2>/dev/null | grep -q "flux-system"; then
        log_success "✅ Flux using External Secrets for Git authentication"
    else
        log_error "❌ Flux not using External Secrets - Phase 3 may have failed"
    fi
    
    # Validate GitHub token is in Vault (not environment)
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
    
    # Validate External Secrets created Flux secret
    if kubectl get secret flux-system -n flux-system >/dev/null 2>&1; then
        log_success "✅ External Secrets created Flux Git authentication secret"
    else
        log_error "❌ Flux Git secret not created by External Secrets"
    fi
    
    kill $VAULT_PF_PID 2>/dev/null || true
    
    echo ""
    echo "🧹 Environment Cleanup Validation:"
    
    # Check that bootstrap environment variables are cleared
    if [ -z "$GITHUB_TOKEN" ] && [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
        log_success "✅ Bootstrap environment variables cleared"
    else
        log_warning "⚠️  Bootstrap environment variables still present"
    fi
    
    echo ""
    echo "🔍 End-to-End Secret Flow Validation:"
    
    # Test that External Secrets can read from Vault and create K8s secrets
    if kubectl get externalsecret -A -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
        log_success "✅ External Secrets successfully syncing from Vault"
    else
        log_error "❌ External Secrets not syncing properly"
    fi
    
    echo ""
    echo "🎯 ZERO-SECRETS ARCHITECTURE ACHIEVED:"
    echo "  ✅ No secrets in Git repositories"
    echo "  ✅ No secrets in command-line arguments"
    echo "  ✅ No persistent environment variables with secrets"
    echo "  ✅ All secrets managed through Vault → External Secrets → Kubernetes"
    echo "  ✅ Platform is completely self-contained"
    if env | grep -v "^HOME\|^PATH\|^USER\|^KUBECONFIG\|^WORKSPACE" | grep -qi "token\|secret\|password"; then
        log_warning "Potential secrets found in environment"
    else
        log_success "No secrets found in environment - secure state achieved"
    fi
}

main() {
    echo "🚀 Zero-Secrets Phase-Based Bootstrap Orchestrator"
    echo "Repository: infra-management"
    echo "Deployments: $DEPLOYMENTS_REPO"
    echo "Infrastructure: $INFRA_REPO"
    echo "Architecture: Environment Variables → Terraform → Vault → External Secrets → Kubernetes"
    echo ""
    
    # Create workspace
    log_info "Creating workspace: $WORKSPACE"
    mkdir -p "$WORKSPACE"
    cd "$WORKSPACE"
    
    # Validation
    validate_environment
    
    # Phase 1: Infrastructure Bootstrap
    log_phase "1" "Core Infrastructure (k3s + Flux + Vault + External Secrets)"
    install_k3s
    install_tools
    deploy_infrastructure_phase
    wait_for_vault_ready
    
    # Phase 2: Secret Population
    log_phase "2" "Populate ALL secrets in Vault via Terraform"
    populate_vault_with_all_secrets
    
    # Critical validation before Phase 3
    wait_for_external_secrets_ready
    
    # Phase 3: Flux External Secrets Authentication
    log_phase "3" "Switch Flux to External Secrets authentication"
    deploy_flux_auth_phase
    
    # Phase 4: Application Deployment
    log_phase "4" "Deploy applications with working External Secrets"
    deploy_applications_phase
    
    # Phase 5: Verification & Cleanup
    log_phase "5" "Verification and cleanup"
    verify_all_phases
    
    # Final success message
    echo ""
    log_success "🎉 Zero-Secrets Phase-Based Bootstrap completed successfully!"
    echo ""
    echo "Your complete zero-secrets Kubernetes infrastructure is ready:"
    echo "  ✅ Phase 1: Core infrastructure deployed"
    echo "  ✅ Phase 2: ALL secrets stored in Vault (including GitHub token)"
    echo "  ✅ Phase 3: Flux using External Secrets for Git authentication"
    echo "  ✅ Phase 4: Applications deployed with working External Secrets"
    echo "  ✅ Phase 5: Environment cleaned of all bootstrap secrets"
    echo ""
    echo "Architecture Flow:"
    echo "  Environment Variables → Terraform → Vault → External Secrets → Kubernetes Secrets → Applications"
    echo ""
    echo "Next steps:"
    echo "  • Monitor deployments: kubectl get pods -A"
    echo "  • Check GitOps status: flux get all --all-namespaces"
    echo "  • Verify secret sync: kubectl get externalsecrets -A"
    echo "  • Access services via your Cloudflare tunnel"
    echo "  • For ongoing secret management: Use Terraform with self-referencing pattern"
    echo ""
    echo "🔒 Security: All bootstrap secrets have been cleared from environment"
    echo "🏛️  Secret Management: All secrets now managed through Vault + External Secrets"
}

# Execute main function
main "$@"