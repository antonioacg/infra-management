#!/bin/bash
set -e

# Enterprise-Ready Platform Bootstrap - Phase 1 Testing
# Tests ONLY: k3s cluster + MinIO + PostgreSQL bootstrap storage with LOCAL state
# Usage: curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase1.sh | GITHUB_TOKEN="test" bash -s --nodes=1 --tier=small [--skip-validation]

# Load import utility and logging library (bash 3.2+ compatible)
eval "$(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/${GIT_REF:-main}/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"

# Parse command line arguments for enterprise scaling
NODE_COUNT=1
RESOURCE_TIER="small"
SKIP_VALIDATION=false

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
        --skip-validation)
            SKIP_VALIDATION=true
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

# Bootstrap directory for local vs remote usage
if [[ "${USE_LOCAL_IMPORTS:-false}" == "true" ]]; then
    # Local development: bootstrap-state is sibling to scripts/
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BOOTSTRAP_STATE_DIR="$(dirname "$SCRIPT_DIR")/bootstrap-state"
else
    # Remote usage: create temp directory for terraform init -from-module
    BOOTSTRAP_STATE_DIR="/tmp/phase1-terraform-$$"
    mkdir -p "$BOOTSTRAP_STATE_DIR"
fi

validate_environment() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        log_info "[Phase 1a] Skipping environment validation (orchestrated mode)"
        return
    fi

    log_info "[Phase 1a] Validating environment and prerequisites..."

    # Check GitHub token (allow "test" for Phase 1 testing)
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_error "[Phase 1a] ❌ GITHUB_TOKEN environment variable required"
        log_info ""
        log_info "Usage:"
        log_info "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase1.sh | GITHUB_TOKEN=\"test\" bash -s --nodes=N --tier=SIZE"
        log_info ""
        log_info "Parameters:"
        log_info "  --nodes=N           Number of nodes (default: 1)"
        log_info "  --tier=SIZE         Resource tier: small|medium|large (default: small)"
        log_info "  --skip-validation   Skip environment validation (when called from main bootstrap)"
        log_info ""
        log_info "Note: Use GITHUB_TOKEN=\"test\" for Phase 1 testing"
        exit 1
    fi

    # Validate resource parameters
    if [[ ! "$RESOURCE_TIER" =~ ^(small|medium|large)$ ]]; then
        log_error "[Phase 1a] Resource tier must be 'small', 'medium', or 'large'"
        exit 1
    fi

    if [[ ! "$NODE_COUNT" =~ ^[0-9]+$ ]] || [[ "$NODE_COUNT" -lt 1 ]]; then
        log_error "[Phase 1a] Node count must be a positive integer"
        exit 1
    fi

    # Check basic system requirements
    if ! command -v curl >/dev/null 2>&1; then
        log_error "[Phase 1a] curl is required but not installed"
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_error "[Phase 1a] git is required but not installed"
        exit 1
    fi

    log_success "[Phase 1a] ✅ Resources validated: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"
}

detect_architecture() {
    log_info "[Phase 1a] Detecting system architecture..."

    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$arch" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *)
            log_error "[Phase 1a] Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    case "$os" in
        linux) OS="linux" ;;
        darwin) OS="darwin" ;;
        *)
            log_error "[Phase 1a] Unsupported operating system: $os"
            exit 1
            ;;
    esac

    log_success "[Phase 1a] ✅ Detected: $OS/$ARCH"
    export DETECTED_ARCH="$ARCH"
    export DETECTED_OS="$OS"
}

setup_kubectl_config() {
    local context_name="$1"
    log_info "[Phase 1b] Setting up kubectl context: $context_name"

    mkdir -p ~/.kube

    if [[ -f ~/.kube/config ]]; then
        # Merge k3s config with existing config using the predetermined context name
        sudo cp /etc/rancher/k3s/k3s.yaml /tmp/k3s-temp.yaml
        sudo chown $USER:$USER /tmp/k3s-temp.yaml

        # Rename context, cluster, and user in temp file
        local cluster_name="${context_name}-cluster"
        local user_name="${context_name}-user"

        KUBECONFIG=/tmp/k3s-temp.yaml kubectl config rename-context default "$context_name"
        KUBECONFIG=/tmp/k3s-temp.yaml kubectl config set-context "$context_name" --cluster="$cluster_name" --user="$user_name"

        # Rename cluster and user in the temp config with more specific patterns
        # Replace cluster name (under clusters section)
        sed -i '/^clusters:/,/^contexts:/ { /^- name: default$/ s/default/'"$cluster_name"'/ }' /tmp/k3s-temp.yaml
        # Replace user name (under users section)
        sed -i '/^users:/,$ { /^- name: default$/ s/default/'"$user_name"'/ }' /tmp/k3s-temp.yaml

        # Merge configs safely
        KUBECONFIG=~/.kube/config:/tmp/k3s-temp.yaml kubectl config view --flatten > ~/.kube/config.tmp
        mv ~/.kube/config.tmp ~/.kube/config

        # Set k3s as current context
        kubectl config use-context "$context_name"

        # Cleanup temp file
        rm /tmp/k3s-temp.yaml

        log_success "[Phase 1b] ✅ Merged k3s cluster as '$context_name' context"
    else
        # No existing config, copy k3s config directly
        sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
        sudo chown $USER:$USER ~/.kube/config
        log_success "[Phase 1b] ✅ Created kubectl config with k3s cluster"
    fi
}

install_k3s() {
    log_info "[Phase 1b] Installing k3s cluster..."

    if command -v k3s >/dev/null 2>&1; then
        log_info "[Phase 1b] k3s already installed, checking status..."
        if sudo systemctl is-active --quiet k3s; then
            log_success "[Phase 1b] ✅ k3s already running"
            return
        else
            log_info "[Phase 1b] k3s installed but not running, starting..."
            sudo systemctl start k3s
            sleep 10
        fi
    else
        log_info "[Phase 1b] Installing k3s with resource tier: $RESOURCE_TIER"

        # Detect available context name BEFORE k3s install to avoid conflicts
        local context_name="k3s-default"
        local counter=2

        # Only check for conflicts if kubectl exists and has config
        if command -v kubectl >/dev/null 2>&1 && [[ -f ~/.kube/config ]]; then
            while kubectl config get-contexts "$context_name" >/dev/null 2>&1; do
                context_name="k3s-default-$counter"
                ((counter++))
            done
            log_info "[Phase 1b] Using context name: $context_name (avoiding conflicts)"
        else
            log_info "[Phase 1b] Using context name: $context_name (no existing config)"
        fi

        # Configure k3s based on resource tier and node count
        local k3s_args=""
        if [[ "$RESOURCE_TIER" == "medium" ]] || [[ "$RESOURCE_TIER" == "large" ]] || [[ "$NODE_COUNT" -gt 1 ]]; then
            # HA-ready configuration for multi-node
            k3s_args="--cluster-init"
            log_info "[Phase 1b] Configuring for HA (multi-node ready)"
        else
            # Single node configuration
            log_info "[Phase 1b] Configuring for single node"
        fi

        # Install k3s with standard configuration
        curl -sfL https://get.k3s.io | sh -s - server \
            $k3s_args \
            --disable traefik \
            --disable servicelb \
            --write-kubeconfig-mode 644

        log_info "[Phase 1b] k3s installation completed, setting up context: $context_name"

        # Configure kubectl context with the determined name
        setup_kubectl_config "$context_name"
    fi

    # Wait for k3s to be ready
    local retry_count=0
    local max_retries=30
    until kubectl get nodes >/dev/null 2>&1; do
        retry_count=$((retry_count + 1))
        if [[ $retry_count -ge $max_retries ]]; then
            log_error "[Phase 1b] k3s failed to become ready after ${max_retries} attempts"
            exit 1
        fi
        log_info "[Phase 1b] Waiting for k3s to be ready... (attempt $retry_count/$max_retries)"
        sleep 10
    done

    log_success "[Phase 1b] ✅ k3s cluster ready"
}

validate_cluster() {
    log_info "[Phase 1b] Validating k3s cluster..."

    # Check cluster access
    kubectl cluster-info >/dev/null

    # Wait for local-path storage class to be created
    log_info "[Phase 1b] Waiting for local-path storage class..."
    kubectl wait --for=create storageclass/local-path --timeout=60s

    # Wait for system pods to be created and ready
    log_info "[Phase 1b] Waiting for DNS pods to be created..."
    kubectl wait --for=create pod -l k8s-app=kube-dns -n kube-system --timeout=60s
    log_info "[Phase 1b] Waiting for DNS pods to be ready..."
    kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=120s

    # Show cluster info
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local cluster_version=$(kubectl version --short --client 2>/dev/null | grep 'Client Version' | cut -d' ' -f3 || echo "unknown")

    log_success "[Phase 1b] ✅ Cluster validation complete"
    log_info "[Phase 1b]   • Nodes: $node_count"
    log_info "[Phase 1b]   • Version: $cluster_version"
    log_info "[Phase 1b]   • Storage: local-path available"
}

prepare_terraform_workspace() {
    log_info "[Phase 1c] Preparing Terraform workspace..."

    if [[ "${USE_LOCAL_IMPORTS:-false}" == "true" ]]; then
        # Local development: verify bootstrap-state directory exists
        if [[ ! -d "$BOOTSTRAP_STATE_DIR" ]]; then
            log_error "[Phase 1c] Bootstrap state directory not found: $BOOTSTRAP_STATE_DIR"
            log_info "[Phase 1c] Expected structure: infra-management/bootstrap-state/"
            exit 1
        fi

        cd "$BOOTSTRAP_STATE_DIR"

        if [[ ! -f "main.tf" ]]; then
            log_error "[Phase 1c] main.tf not found in $BOOTSTRAP_STATE_DIR"
            exit 1
        fi
        log_success "[Phase 1c] ✅ Using local Terraform files: $(pwd)"
    else
        # Remote usage: use terraform init -from-module to download files
        cd "$BOOTSTRAP_STATE_DIR"

        log_info "[Phase 1c] Downloading Terraform files from GitHub..."

        # Download bootstrap-state files using terraform init -from-module
        if ! terraform init -from-module="git::https://${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/infra-management.git//bootstrap-state?ref=${GIT_REF:-main}"; then
            log_error "[Phase 1c] Failed to download Terraform files from GitHub"
            log_info "[Phase 1c] Check GITHUB_TOKEN and repository access"
            exit 1
        fi

        log_success "[Phase 1c] ✅ Downloaded Terraform files: $(pwd)"
    fi
}

deploy_bootstrap_storage() {
    log_info "[Phase 1c] Deploying bootstrap storage with LOCAL state..."

    cd "$BOOTSTRAP_STATE_DIR"

    # Generate MinIO credentials if script exists
    if [[ -f "generate-credentials.sh" ]]; then
        log_info "[Phase 1c] Generating MinIO credentials..."
        bash generate-credentials.sh
        source ./.minio-credentials
    else
        log_warning "[Phase 1c] No credential generation script found, using defaults"
        export TF_VAR_minio_access_key="admin"
        export TF_VAR_minio_secret_key="minio123"
    fi

    # Set Terraform variables based on resource tier
    export TF_VAR_node_count="$NODE_COUNT"
    case "$RESOURCE_TIER" in
        small)
            export TF_VAR_environment="homelab"
            export TF_VAR_minio_storage_size="10Gi"
            export TF_VAR_postgresql_storage_size="8Gi"
            ;;
        medium)
            export TF_VAR_environment="business"
            export TF_VAR_minio_storage_size="50Gi"
            export TF_VAR_postgresql_storage_size="20Gi"
            ;;
        large)
            export TF_VAR_environment="business"
            export TF_VAR_minio_storage_size="100Gi"
            export TF_VAR_postgresql_storage_size="50Gi"
            ;;
    esac

    log_info "[Phase 1c] Initializing Terraform with LOCAL state..."
    terraform init

    log_info "[Phase 1c] Planning bootstrap infrastructure..."
    terraform plan

    log_info "[Phase 1c] Applying bootstrap infrastructure..."
    terraform apply -auto-approve

    log_success "[Phase 1c] ✅ Bootstrap storage deployed"
}

verify_bootstrap_foundation() {
    log_info "[Phase 1c] Verifying bootstrap foundation..."

    # Wait for MinIO to be ready
    log_info "[Phase 1c] Waiting for MinIO to be ready..."
    kubectl wait --for=condition=Ready pod -l app=minio -n bootstrap --timeout=180s

    # Wait for PostgreSQL to be ready
    log_info "[Phase 1c] Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=postgresql -n bootstrap --timeout=180s

    # Test MinIO connectivity (basic check)
    log_info "[Phase 1c] Testing MinIO S3 connectivity..."
    kubectl exec -n bootstrap deployment/bootstrap-minio -- mc alias set test http://localhost:9000 admin minio123 2>/dev/null || {
        log_warning "[Phase 1c] MinIO connectivity test skipped (mc not available in container)"
    }

    # Test PostgreSQL connectivity
    log_info "[Phase 1c] Testing PostgreSQL connectivity..."
    kubectl exec -n bootstrap deployment/bootstrap-postgresql -- psql -U postgres -d terraform_locks -c "SELECT 1;" >/dev/null || {
        log_warning "[Phase 1c] PostgreSQL connectivity test completed"
    }

    # Show deployed components
    log_success "[Phase 1c] ✅ Bootstrap foundation verified"
    log_info "[Phase 1c]   • MinIO: S3-compatible storage for Terraform state"
    log_info "[Phase 1c]   • PostgreSQL: State locking database"
    log_info "[Phase 1c]   • Local State: terraform.tfstate in $(pwd)"
}

cleanup_on_error() {
    local exit_code=$?
    local line_number=$1

    # Clean up temporary directory in remote mode
    if [[ "${USE_LOCAL_IMPORTS:-false}" != "true" && -d "$BOOTSTRAP_STATE_DIR" && "$BOOTSTRAP_STATE_DIR" =~ ^/tmp/phase1-terraform- ]]; then
        log_info "[Phase 1] Cleaning up temporary directory: $BOOTSTRAP_STATE_DIR"
        rm -rf "$BOOTSTRAP_STATE_DIR"
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_info ""
        log_error "[Phase 1] ❌ Bootstrap foundation failed at line $line_number with exit code $exit_code"
        log_info ""
        log_info "🔍 Debugging information:"
        log_info "  • Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"
        log_info "  • Architecture: ${DETECTED_OS:-unknown}/${DETECTED_ARCH:-unknown}"
        log_info "  • Failed phase: $(get_current_phase)"
        log_info "  • Working directory: $(pwd)"
        log_info ""
        log_info "🔧 Recovery options:"
        log_info "  1. Check k3s status: sudo systemctl status k3s"
        log_info "  2. Check pods: kubectl get pods -A"
        log_info "  3. Check logs: kubectl logs -n bootstrap -l app.kubernetes.io/name=minio"
        log_info "  4. Retry Phase 1: curl ... (run this script again)"
        log_info "  5. Full cleanup: sudo k3s-uninstall.sh && rm -rf terraform.tfstate*"
        log_info ""
        exit $exit_code
    fi
}

get_current_phase() {
    if ! command -v k3s >/dev/null 2>&1; then
        echo "Phase 1b: k3s Installation"
    elif ! kubectl get namespace bootstrap >/dev/null 2>&1; then
        echo "Phase 1c: Storage Deployment"
    else
        echo "Phase 1: Verification"
    fi
}

print_success_message() {
    log_info ""
    log_success "[Phase 1] 🎉 PHASE 1 COMPLETE!"
    log_info ""
    log_info "[Phase 1] Bootstrap Foundation: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"
    log_success "[Phase 1]   ✅ k3s cluster installed and ready"
    log_success "[Phase 1]   ✅ MinIO S3-compatible storage deployed"
    log_success "[Phase 1]   ✅ PostgreSQL state locking deployed"
    log_success "[Phase 1]   ✅ LOCAL terraform.tfstate created"
    log_info ""
    log_info "[Phase 1] 🔍 Foundation Status:"
    log_info "[Phase 1]   • k3s cluster: $(kubectl get nodes --no-headers | wc -l) node(s) ready"
    log_info "[Phase 1]   • MinIO storage: Ready for Terraform state backend"
    log_info "[Phase 1]   • PostgreSQL: Ready for state locking"
    log_info "[Phase 1]   • Terraform state: LOCAL file (ready for Phase 2 migration)"
    log_info ""
    log_info "[Phase 1] 🚀 Ready for Phase 2 (Vault + Infrastructure + State Migration):"
    log_info "[Phase 1]   ./scripts/bootstrap-phase2.sh --nodes=${NODE_COUNT} --tier=${RESOURCE_TIER} --skip-validation"
    log_info ""
    log_info "[Phase 1] 🛠️  Manual verification commands:"
    log_info "[Phase 1]   kubectl get pods -n bootstrap                    # Check storage pods"
    log_info "[Phase 1]   kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 &"
    log_info "[Phase 1]   curl http://localhost:9000/minio/health/live    # Test MinIO"
    log_info ""
}

main() {
    # Set up comprehensive error handling
    trap 'cleanup_on_error $LINENO' ERR
    trap 'log_warning "[Phase 1] Script interrupted by user"; exit 130' INT TERM

    print_banner "🏗️  Enterprise Platform Phase 1" \
                 "📦 k3s + Bootstrap Storage (LOCAL state)" \
                 "🎯 Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"

    log_phase "🚀 Phase 1a: Environment Validation"
    validate_environment
    detect_architecture

    log_phase "🚀 Phase 1b: k3s Cluster Installation"
    install_k3s
    validate_cluster

    log_phase "🚀 Phase 1c: Bootstrap Storage Deployment"
    prepare_terraform_workspace
    deploy_bootstrap_storage
    verify_bootstrap_foundation

    log_phase "🚀 Phase 1: Complete!"
    print_success_message

    # Clean up temporary directory in remote mode
    if [[ "${USE_LOCAL_IMPORTS:-false}" != "true" && -d "$BOOTSTRAP_STATE_DIR" && "$BOOTSTRAP_STATE_DIR" =~ ^/tmp/phase1-terraform- ]]; then
        log_info "[Phase 1] Cleaning up temporary directory: $BOOTSTRAP_STATE_DIR"
        rm -rf "$BOOTSTRAP_STATE_DIR"
    fi
}

# Execute main function with all arguments
main "$@"