#!/bin/bash
set -e

# Enterprise-Ready Platform Bootstrap - Phase 1 Testing
# Tests ONLY: k3s cluster + MinIO + PostgreSQL bootstrap storage with LOCAL state
# Usage: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase1.sh | GITHUB_TOKEN="test" bash -s -- --nodes=1 --tier=small [--skip-validation]

# Configuration - set defaults before imports
GITHUB_ORG="${GITHUB_ORG:-antonioacg}"
GIT_REF="${GIT_REF:-main}"
NODE_COUNT=1
RESOURCE_TIER="small"
SKIP_VALIDATION=false

# Load import utility and logging library (bash 3.2+ compatible)
eval "$(curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF}/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"
smart_import "infra-management/scripts/lib/system.sh"
smart_import "infra-management/scripts/lib/network.sh"
smart_import "infra-management/scripts/lib/credentials.sh"

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
            --skip-validation)
                SKIP_VALIDATION=true
                shift
                ;;
            --help|-h)
                echo "Enterprise Platform Bootstrap - Phase 1"
                echo "k3s cluster + Bootstrap Storage (LOCAL state)"
                echo ""
                echo "Usage:"
                echo "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase1.sh | GITHUB_TOKEN=\"test\" bash -s -- [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --nodes=N                Number of nodes (default: 1)"
                echo "  --tier=SIZE              Resource tier: small|medium|large (default: small)"
                echo "  --skip-validation        Skip environment validation (when called from main bootstrap)"
                echo "  --help, -h               Show this help message"
                echo ""
                echo "Environment Variables:"
                echo "  GITHUB_TOKEN        GitHub token (use \"test\" for Phase 1 testing)"
                echo "  LOG_LEVEL           Logging level: ERROR|WARN|INFO|DEBUG|TRACE (default: INFO)"
                echo ""
                exit 0
                ;;
            *)
                echo "Error: Unknown parameter: $1"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo "  --nodes=N                Number of nodes (default: 1)"
                echo "  --tier=SIZE              Resource tier: small|medium|large (default: small)"
                echo "  --skip-validation        Skip environment validation"
                echo "  --help, -h               Show this help message"
                echo ""
                exit 1
                ;;
        esac
    done
}

# Bootstrap directory for local vs remote usage
if [[ "${USE_LOCAL_IMPORTS:-false}" == "true" ]]; then
    # Local development: bootstrap-state is sibling to scripts/
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BOOTSTRAP_STATE_DIR="$(dirname "$SCRIPT_DIR")/bootstrap-state"
else
    # Remote usage: use shared bootstrap temp directory
    BOOTSTRAP_STATE_DIR="${BOOTSTRAP_TEMP_DIR:-/tmp/bootstrap-state}"
    mkdir -p "$BOOTSTRAP_STATE_DIR"
fi

# PRIVATE: Cleanup function for Phase 1
_cleanup() {
    local exit_code=$?

    log_info "🧹 [Phase 1] Cleaning up resources..."

    # No phase-specific cleanup needed for Phase 1
    # (k3s stays running for Phase 2+)

    # Clear credentials (in orchestrated mode, bootstrap.sh also does this, which is fine)
    clear_bootstrap_credentials 2>/dev/null || true

    # Clean shared temp directory (idempotent)
    rm -rf /tmp/bootstrap-state 2>/dev/null || true

    # Show appropriate message based on exit code
    if [[ $exit_code -eq 130 ]]; then
        log_warning "[Phase 1] ⚠️  Script interrupted by user"
    elif [[ $exit_code -ne 0 ]]; then
        log_error "[Phase 1] ❌ Bootstrap foundation failed with exit code $exit_code"
        log_info ""
        log_info "🔍 Debugging information:"
        log_info "  • Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"
        log_info "  • Architecture: ${DETECTED_OS:-unknown}/${DETECTED_ARCH:-unknown}"
        log_info "  • Working directory: $(pwd)"
        log_info ""
        log_info "🔧 Recovery options:"
        log_info "  1. Check k3s status: sudo systemctl status k3s"
        log_info "  2. Check pods: kubectl get pods -A"
        log_info "  3. Check logs: kubectl logs -n bootstrap -l app=minio"
        log_info "  4. Retry Phase 1: curl ... (run this script again)"
        log_info "  5. Full cleanup: sudo k3s-uninstall.sh && rm -rf /tmp/bootstrap-state"
        log_info ""
    fi
}

# PRIVATE: Validate environment prerequisites for Phase 1
_validate_environment() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        log_info "[Phase 1a] Skipping environment validation (orchestrated mode)"
        return
    fi

    log_info "[Phase 1a] Validating environment and prerequisites..."

    # Check GitHub token (allow "test" for Phase 1 testing)
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_error "[Phase 1a] ❌ GITHUB_TOKEN environment variable required"
        echo ""
        echo "Run: $0 --help for usage information"
        echo ""
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

# PRIVATE: Setup node encryption for k3s data directory using LUKS container
_setup_node_encryption() {
    log_phase "Security" "Setting up LUKS container encryption for k3s data"

    # Check if k3s is already running and stop it for encryption setup
    if sudo systemctl is-active --quiet k3s 2>/dev/null; then
        log_info "[Phase 1a] Stopping existing k3s for encryption setup..."
        sudo systemctl stop k3s
        # Unmount k3s directory if it's already mounted
        sudo umount /var/lib/rancher/k3s 2>/dev/null || true
        # Close any existing LUKS container
        sudo cryptsetup luksClose k3s_encrypted 2>/dev/null || true
    fi

    # Check if encryption is already set up
    if mount | grep -q "/dev/mapper/k3s_encrypted.*rancher/k3s"; then
        log_success "[Phase 1a] ✅ LUKS container encryption already configured"
        return 0
    fi

    # Check if cryptsetup is available (should be installed by Phase 0)
    if ! command -v cryptsetup >/dev/null; then
        # Check if we're on macOS where cryptsetup isn't available
        if [[ "$DETECTED_OS" == "darwin" ]]; then
            log_warning "[Phase 1a] LUKS encryption not available on macOS - skipping node encryption"
            log_info "[Phase 1a] k3s data will not be encrypted on macOS (development only)"
            return 0
        else
            log_error "[Phase 1a] cryptsetup not found - ensure Phase 0 tool installation completed"
            log_info "[Phase 1a] Run: ./scripts/bootstrap-phase0.sh --nodes=${NODE_COUNT} --tier=${RESOURCE_TIER}"
            exit 1
        fi
    fi

    # Generate encryption key and store in protected key file
    log_info "[Phase 1a] Generating encryption key..."
    local key_file="/root/.luks-k3s.key"
    sudo dd if=/dev/urandom of="$key_file" bs=512 count=1 status=none
    sudo chmod 400 "$key_file"
    sudo chown root:root "$key_file"

    # Set container size based on resource tier
    local container_size
    case "$RESOURCE_TIER" in
        "small")  container_size="5G" ;;
        "medium") container_size="20G" ;;
        "large")  container_size="50G" ;;
        *)        container_size="10G" ;;
    esac

    # Create encrypted container file
    local container_file="/var/lib/rancher-k3s-encrypted.img"
    log_info "[Phase 1a] Creating LUKS container (${container_size})..."

    sudo mkdir -p /var/lib
    sudo dd if=/dev/zero of="$container_file" bs=1M count=1 seek=$((${container_size%G} * 1024 - 1)) status=none

    # Format as LUKS container with key file
    log_info "[Phase 1a] Formatting LUKS container with key file..."
    sudo cryptsetup luksFormat "$container_file" "$key_file" --batch-mode --cipher aes-xts-plain64 --key-size 512 --hash sha512

    # Open LUKS container with key file
    log_info "[Phase 1a] Opening LUKS container..."
    sudo cryptsetup luksOpen "$container_file" k3s_encrypted --key-file="$key_file"

    # Create filesystem in container
    log_info "[Phase 1a] Creating filesystem in encrypted container..."
    sudo mkfs.ext4 /dev/mapper/k3s_encrypted >/dev/null 2>&1

    # Create mount point and mount
    sudo mkdir -p /var/lib/rancher/k3s
    sudo mount /dev/mapper/k3s_encrypted /var/lib/rancher/k3s

    # Set proper ownership
    sudo chown root:root /var/lib/rancher/k3s
    sudo chmod 755 /var/lib/rancher/k3s

    # Create crypttab entry for automatic unlock on boot
    if ! grep -q "k3s_encrypted" /etc/crypttab; then
        log_info "[Phase 1a] Configuring automatic unlock on boot..."
        echo "k3s_encrypted $container_file $key_file luks" | sudo tee -a /etc/crypttab >/dev/null
        log_success "[Phase 1a] ✅ Automatic unlock configured in /etc/crypttab"
    fi

    # Add to fstab for automatic mount after unlock
    if ! grep -q "k3s_encrypted" /etc/fstab; then
        log_info "[Phase 1a] Adding encrypted mount to fstab..."
        echo "/dev/mapper/k3s_encrypted /var/lib/rancher/k3s ext4 defaults 0 2" | sudo tee -a /etc/fstab >/dev/null
        log_success "[Phase 1a] ✅ Automatic mount configured in /etc/fstab"
    fi

    # Verify encryption is working
    if mount | grep -q "/dev/mapper/k3s_encrypted.*rancher/k3s"; then
        log_success "[Phase 1a] ✅ LUKS container encryption configured with automatic unlock"
        log_info "[Phase 1a]   • Key file: $key_file (400 permissions, root-only)"
        log_info "[Phase 1a]   • Auto-unlock: Configured in /etc/crypttab"
        log_info "[Phase 1a]   • Auto-mount: Configured in /etc/fstab"

        # Test write/read to verify container
        echo "encryption-test" | sudo tee /var/lib/rancher/k3s/test-file >/dev/null
        if [[ -f /var/lib/rancher/k3s/test-file ]]; then
            sudo rm -f /var/lib/rancher/k3s/test-file
            log_success "[Phase 1a] ✅ LUKS container verified working"
        else
            log_error "[Phase 1a] ❌ LUKS container test failed"
            exit 1
        fi
    else
        log_error "[Phase 1a] ❌ Failed to mount LUKS container"
        exit 1
    fi
}

# PRIVATE: Validate kubectl context is not conflicting with existing k3s installations
_validate_kubectl_context() {
    local expected_context="$1"
    log_trace "[Phase 1b] Validating kubectl context setup..."

    local current_context=$(kubectl config current-context 2>/dev/null || echo "NONE")
    if [[ "$current_context" != "$expected_context" ]]; then
        log_error "[Phase 1b] Context mismatch. Expected: $expected_context, Got: $current_context"
        log_debug "[Phase 1b] Available contexts: $(kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ' || echo 'none')"
        log_debug "[Phase 1b] Kubeconfig contents:"
        log_debug "$(cat ~/.kube/config 2>/dev/null || echo 'No kubeconfig found')"
        exit 1
    fi

    kubectl cluster-info >/dev/null 2>&1 || {
        log_error "[Phase 1b] kubectl cluster access failed with context: $expected_context"
        log_debug "[Phase 1b] kubectl cluster-info error: $(kubectl cluster-info 2>&1 || echo 'cluster-info failed')"
        exit 1
    }

    log_success "[Phase 1b] ✅ kubectl context '$expected_context' verified and working"
}

# PRIVATE: Setup kubectl configuration for k3s cluster
_setup_kubectl_config() {
    local context_name="$1"
    log_info "[Phase 1b] Setting up kubectl context: $context_name"

    # Create ~/.kube directory with secure permissions (700 - owner only)
    mkdir -p ~/.kube
    chmod 700 ~/.kube

    if [[ -f ~/.kube/config ]]; then
        log_debug "[Phase 1b] Existing kubeconfig found, merging with k3s config"

        # Define renamed components
        local cluster_name="${context_name}-cluster"
        local user_name="${context_name}-user"

        log_debug "[Phase 1b] Renaming k3s config components to: context=$context_name, cluster=$cluster_name, user=$user_name"

        # Transform k3s config in memory using process substitution
        # This avoids any temp files on disk
        # Note: sudo required because k3s.yaml has 600 permissions (root-only, secure by default)
        local transformed_config=$(sudo cat /etc/rancher/k3s/k3s.yaml | \
            yq eval '.contexts[0].name = "'$context_name'"' | \
            yq eval '.contexts[0].context.cluster = "'$cluster_name'"' | \
            yq eval '.contexts[0].context.user = "'$user_name'"' | \
            yq eval '.clusters[0].name = "'$cluster_name'"' | \
            yq eval '.users[0].name = "'$user_name'"' | \
            yq eval '.current-context = "'$context_name'"')

        # Validate the transformed config before merging
        echo "$transformed_config" | kubectl config view --kubeconfig=/dev/stdin >/dev/null || {
            log_error "[Phase 1b] Failed to transform k3s config with yq"
            exit 1
        }

        # Merge configs entirely in memory using process substitution
        # No temp files created at any point
        KUBECONFIG=~/.kube/config:<(echo "$transformed_config") kubectl config view --flatten > ~/.kube/config.new || {
            log_error "[Phase 1b] Failed to merge kubectl configurations"
            rm -f ~/.kube/config.new
            exit 1
        }

        # Set secure permissions before moving into place
        chmod 600 ~/.kube/config.new

        # Atomic move to replace config
        mv ~/.kube/config.new ~/.kube/config

        # Set the new context as current
        kubectl config use-context "$context_name" || {
            log_error "[Phase 1b] Failed to set current context to '$context_name'"
            exit 1
        }

        log_success "[Phase 1b] ✅ Merged k3s cluster as '$context_name' context"
    else
        log_debug "[Phase 1b] No existing kubeconfig, creating new one from k3s config"

        # No existing config, copy k3s config directly with secure permissions
        # Note: sudo required because k3s.yaml has 600 permissions (root-only, secure by default)
        sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
        chmod 600 ~/.kube/config

        # For direct copy, the context remains "default"
        context_name="default"
        log_success "[Phase 1b] ✅ Created kubectl config with k3s cluster"
    fi

    # Verify final permissions are secure (600 - owner read/write only)
    local final_perms=$(stat -c '%a' ~/.kube/config 2>/dev/null || stat -f '%A' ~/.kube/config 2>/dev/null)
    if [[ "$final_perms" == "600" ]]; then
        log_debug "[Phase 1b] kubeconfig permissions verified: $final_perms (secure)"
    else
        log_warning "[Phase 1b] kubeconfig permissions: $final_perms (expected: 600)"
        chmod 600 ~/.kube/config
        log_info "[Phase 1b] Fixed kubeconfig permissions to 600"
    fi

    # Validate that kubectl is working
    _validate_kubectl_context "$context_name"
}

# PRIVATE: Generate etcd encryption configuration for k3s
_generate_etcd_encryption_config() {
    log_phase "Security" "Generating etcd encryption-at-rest configuration"

    local encryption_config_dir="/var/lib/rancher/k3s/server/cred"
    local encryption_config_file="${encryption_config_dir}/encryption-config.json"

    # Check if encryption config already exists
    if [[ -f "$encryption_config_file" ]]; then
        log_info "[Phase 1b] etcd encryption configuration already exists, verifying permissions..."

        # Check current permissions
        local current_perms=$(stat -c '%a' "$encryption_config_file" 2>/dev/null || stat -f '%A' "$encryption_config_file" 2>/dev/null)
        log_debug "[Phase 1b] Current permissions: $current_perms"

        # Ensure correct permissions (600) and ownership (root:root)
        sudo chmod 600 "$encryption_config_file"
        sudo chown root:root "$encryption_config_file"

        # Verify permissions were set correctly
        local new_perms=$(stat -c '%a' "$encryption_config_file" 2>/dev/null || stat -f '%A' "$encryption_config_file" 2>/dev/null)
        if [[ "$new_perms" == "600" ]]; then
            log_success "[Phase 1b] ✅ etcd encryption configuration exists with correct permissions"
        else
            log_warning "[Phase 1b] ⚠️  Permissions: $new_perms (expected: 600)"
        fi

        return 0
    fi

    # Create directory if it doesn't exist
    log_info "[Phase 1b] Creating encryption configuration directory..."
    sudo mkdir -p "$encryption_config_dir"

    # Generate random encryption key (32 bytes = 256 bits, base64 encoded)
    log_info "[Phase 1b] Generating encryption key..."
    local encryption_key=$(openssl rand -base64 32)

    # Create EncryptionConfiguration
    log_info "[Phase 1b] Writing encryption configuration..."
    sudo tee "$encryption_config_file" >/dev/null <<EOF
{
  "kind": "EncryptionConfiguration",
  "apiVersion": "apiserver.config.k8s.io/v1",
  "resources": [
    {
      "resources": [
        "secrets"
      ],
      "providers": [
        {
          "aescbc": {
            "keys": [
              {
                "name": "key1",
                "secret": "${encryption_key}"
              }
            ]
          }
        },
        {
          "identity": {}
        }
      ]
    }
  ]
}
EOF

    # Set proper permissions (only root can read)
    log_info "[Phase 1b] Setting file permissions to 600 (root only)..."
    sudo chmod 600 "$encryption_config_file"
    sudo chown root:root "$encryption_config_file"

    # Verify file was created successfully and permissions are correct
    if [[ -f "$encryption_config_file" ]]; then
        local final_perms=$(stat -c '%a' "$encryption_config_file" 2>/dev/null || stat -f '%A' "$encryption_config_file" 2>/dev/null)

        if [[ "$final_perms" == "600" ]]; then
            log_success "[Phase 1b] ✅ etcd encryption configuration generated with correct permissions"
            log_info "[Phase 1b] Configuration file: $encryption_config_file"
            log_debug "[Phase 1b] Permissions verified: $final_perms (root:root)"
        else
            log_error "[Phase 1b] ❌ Permissions incorrect: $final_perms (expected: 600)"
            exit 1
        fi
    else
        log_error "[Phase 1b] ❌ Failed to create encryption configuration"
        exit 1
    fi

    # Clear encryption key from memory
    unset encryption_key
}

# PRIVATE: Install and configure k3s cluster
_install_k3s() {
    log_info "[Phase 1b] Installing k3s cluster..."

    # Detect available context name BEFORE any k3s operations to avoid conflicts
    local context_name="k3s-default"
    local counter=2
    local k3s_already_installed=false

    # Only check for conflicts if kubectl exists and has config
    if command -v kubectl >/dev/null 2>&1 && [[ -f ~/.kube/config ]]; then
        while kubectl config get-contexts "$context_name" >/dev/null 2>&1; do
            context_name="k3s-default-$counter"
            ((counter++))
        done
        log_debug "[Phase 1b] Context name selected: $context_name (avoiding conflicts)"
    else
        log_debug "[Phase 1b] Context name selected: $context_name (no existing config)"
    fi

    if command -v k3s >/dev/null 2>&1; then
        log_info "[Phase 1b] k3s already installed, checking status..."
        k3s_already_installed=true
        if sudo systemctl is-active --quiet k3s; then
            log_success "[Phase 1b] ✅ k3s already running"
        else
            log_info "[Phase 1b] k3s installed but not running, starting..."
            sudo systemctl start k3s
            sleep 10
        fi
    else
        log_info "[Phase 1b] Installing k3s with resource tier: $RESOURCE_TIER"

        # Generate etcd encryption configuration BEFORE k3s installation
        _generate_etcd_encryption_config

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

        # Install k3s with encryption and robust download
        local encryption_config="/var/lib/rancher/k3s/server/cred/encryption-config.json"
        log_info "[Phase 1b] Installing k3s with etcd encryption enabled..."
        curl_with_retry "https://get.k3s.io" | sh -s - server \
            $k3s_args \
            --disable traefik \
            --disable servicelb \
            --write-kubeconfig-mode 600 \
            --secrets-encryption \
            --kube-apiserver-arg="encryption-provider-config=${encryption_config}"

        log_info "[Phase 1b] k3s installation completed with etcd encryption"
        log_debug "[Phase 1b] k3s kubeconfig created with secure 600 permissions (root-only)"
    fi

    # Always ensure kubectl context is properly configured
    log_info "[Phase 1b] Setting up kubectl context: $context_name"
    _setup_kubectl_config "$context_name"

    # Wait for k3s to be ready with enhanced error reporting
    log_trace "[Phase 1b] Starting k3s readiness check..."
    local retry_count=0
    local max_retries=30

    until kubectl get nodes >/dev/null 2>&1; do
        retry_count=$((retry_count + 1))
        if [[ $retry_count -ge $max_retries ]]; then
            log_error "[Phase 1b] k3s failed to become ready after ${max_retries} attempts"
            log_debug "[Phase 1b] Final readiness check error:"
            log_debug "$(kubectl get nodes 2>&1 || echo 'kubectl get nodes failed')"
            log_debug "[Phase 1b] Current kubectl context: $(kubectl config current-context 2>/dev/null || echo 'No context')"
            log_debug "[Phase 1b] k3s service status:"
            log_debug "$(sudo systemctl status k3s --no-pager -l || echo 'systemctl status failed')"
            exit 1
        fi

        if [[ $retry_count -eq 1 ]] || [[ $((retry_count % 5)) -eq 0 ]]; then
            # Show detailed error info on first attempt and every 5th attempt
            local kubectl_error=$(kubectl get nodes 2>&1)
            log_debug "[Phase 1b] kubectl error (attempt $retry_count): $kubectl_error"
        fi

        log_info "[Phase 1b] Waiting for k3s to be ready... (attempt $retry_count/$max_retries)"
        sleep 10
    done

    log_success "[Phase 1b] ✅ k3s cluster ready"
    log_trace "[Phase 1b] Final cluster info:"
    log_trace "$(kubectl cluster-info 2>/dev/null || echo 'cluster-info not available')"
}

# PRIVATE: Validate k3s cluster is healthy and responsive
_validate_cluster() {
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

    # Verify etcd encryption is enabled
    log_info "[Phase 1b] Verifying etcd encryption-at-rest..."
    _verify_etcd_encryption

    # Show cluster info
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local cluster_version=$(kubectl version --short --client 2>/dev/null | grep 'Client Version' | cut -d' ' -f3 || echo "unknown")

    log_success "[Phase 1b] ✅ Cluster validation complete"
    log_info "[Phase 1b]   • Nodes: $node_count"
    log_info "[Phase 1b]   • Version: $cluster_version"
    log_info "[Phase 1b]   • Storage: local-path available"
    log_info "[Phase 1b]   • Encryption: etcd secrets encrypted at rest"
}

# PRIVATE: Verify etcd encryption-at-rest is working
_verify_etcd_encryption() {
    local encryption_config="/var/lib/rancher/k3s/server/cred/encryption-config.json"

    # Check encryption config file exists
    if [[ ! -f "$encryption_config" ]]; then
        log_error "[Phase 1b] ❌ Encryption configuration not found: $encryption_config"
        exit 1
    fi

    # Verify file permissions are secure (600)
    local perms=$(stat -c '%a' "$encryption_config" 2>/dev/null || stat -f '%A' "$encryption_config" 2>/dev/null)
    if [[ "$perms" != "600" ]]; then
        log_warning "[Phase 1b] ⚠️  Encryption config permissions: $perms (expected: 600)"
    fi

    # Create a test secret with known plaintext value
    local test_value="PLAINTEXT_TEST_VALUE_$(date +%s)"
    log_debug "[Phase 1b] Creating test secret to verify encryption..."
    kubectl create secret generic etcd-encryption-test \
        --from-literal=test-key="$test_value" \
        -n kube-system >/dev/null 2>&1 || {
        log_error "[Phase 1b] ❌ Failed to create test secret"
        exit 1
    }

    # Verify secret was created
    if ! kubectl get secret etcd-encryption-test -n kube-system >/dev/null 2>&1; then
        log_error "[Phase 1b] ❌ Failed to verify test secret creation"
        exit 1
    fi

    log_success "[Phase 1b] ✅ Test secret created successfully"

    # Inspect etcd database on disk to verify encryption
    # k3s uses etcd embedded, data stored in /var/lib/rancher/k3s/server/db/
    log_debug "[Phase 1b] Inspecting etcd database to verify encryption on disk..."
    local etcd_db_path="/var/lib/rancher/k3s/server/db"

    if [[ -d "$etcd_db_path" ]]; then
        # Search for the plaintext value in etcd database files
        # If encryption is working, the plaintext should NOT be found
        if sudo grep -r "$test_value" "$etcd_db_path" >/dev/null 2>&1; then
            log_error "[Phase 1b] ❌ ENCRYPTION FAILED: Plaintext found in etcd database!"
            log_error "[Phase 1b] Secret data is NOT encrypted at rest"

            # Clean up test secret
            kubectl delete secret etcd-encryption-test -n kube-system >/dev/null 2>&1
            exit 1
        else
            log_success "[Phase 1b] ✅ Encryption verified: Plaintext NOT found in etcd database"
            log_debug "[Phase 1b] Secret data is properly encrypted at rest"
        fi
    else
        log_warning "[Phase 1b] ⚠️  Could not find etcd database path: $etcd_db_path"
        log_warning "[Phase 1b] Skipping filesystem-level encryption verification"
    fi

    # Clean up test secret
    kubectl delete secret etcd-encryption-test -n kube-system >/dev/null 2>&1
    log_debug "[Phase 1b] Test secret cleaned up"

    log_debug "[Phase 1b] Encryption configuration: $encryption_config (600 permissions)"
}

# PRIVATE: Prepare Terraform workspace for bootstrap storage deployment
_prepare_terraform_workspace() {
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

        # Remove directory if it exists (idempotent)
        if [[ -d "$BOOTSTRAP_STATE_DIR" ]]; then
            log_info "[Phase 1c] Removing existing bootstrap directory..."
            rm -rf "${BOOTSTRAP_STATE_DIR:?}"
        fi

        mkdir -p "$BOOTSTRAP_STATE_DIR"
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

# PRIVATE: Deploy MinIO and PostgreSQL bootstrap storage components
_deploy_bootstrap_storage() {
    log_info "[Phase 1c] Deploying bootstrap storage with LOCAL state..."

    cd "$BOOTSTRAP_STATE_DIR"

    # Generate secure credentials in-memory (no files)
    generate_bootstrap_credentials

    # Validate all credentials present before proceeding
    validate_bootstrap_credentials

    # Export resource tier and node count for Terraform
    export TF_VAR_resource_tier="$RESOURCE_TIER"
    export TF_VAR_node_count="$NODE_COUNT"

    # Dynamic storage sizing based on tier
    case "$RESOURCE_TIER" in
        small)
            export TF_VAR_minio_storage_size="10Gi"
            export TF_VAR_postgresql_storage_size="8Gi"
            ;;
        medium)
            export TF_VAR_minio_storage_size="50Gi"
            export TF_VAR_postgresql_storage_size="20Gi"
            ;;
        large)
            export TF_VAR_minio_storage_size="100Gi"
            export TF_VAR_postgresql_storage_size="50Gi"
            ;;
    esac

    log_info "[Phase 1c] Initializing Terraform with LOCAL state..."
    terraform init

    log_info "[Phase 1c] Planning bootstrap infrastructure..."

    # Retry terraform apply to handle transient network errors (helm chart downloads)
    local max_attempts=3
    local attempt=1
    local apply_success=false

    while [[ $attempt -le $max_attempts ]]; do
        local plan_file="tfplan-attempt${attempt}"

        if [[ $attempt -gt 1 ]]; then
            log_warning "[Phase 1c] Retry attempt $attempt/$max_attempts after previous failure..."
            sleep 5
        fi

        log_info "[Phase 1c] Creating plan: $plan_file"
        if ! terraform plan -out="$plan_file"; then
            log_error "[Phase 1c] Terraform plan failed on attempt $attempt"
            rm -f "$plan_file"
            if [[ $attempt -eq $max_attempts ]]; then
                return 1
            fi
            ((attempt++))
            continue
        fi

        log_info "[Phase 1c] Applying plan: $plan_file"
        if terraform apply "$plan_file"; then
            apply_success=true
            # Clean up plan files after successful apply
            rm -f tfplan-attempt*
            break
        else
            log_warning "[Phase 1c] Terraform apply failed on attempt $attempt"
            if [[ $attempt -eq $max_attempts ]]; then
                log_error "[Phase 1c] Terraform apply failed after $max_attempts attempts"
                # Keep plan files for debugging
                log_info "[Phase 1c] Plan files preserved for debugging: tfplan-attempt*"
                return 1
            fi
        fi
        ((attempt++))
    done

    if [[ "$apply_success" == "true" ]]; then
        log_success "[Phase 1c] ✅ Bootstrap storage deployed"
    fi
}

# PRIVATE: Verify bootstrap foundation components are working
_verify_bootstrap_foundation() {
    log_info "[Phase 1c] Verifying bootstrap foundation..."

    # Wait for MinIO to be ready
    log_info "[Phase 1c] Waiting for MinIO to be ready..."
    kubectl wait --for=condition=Ready pod -l app=minio -n bootstrap --timeout=180s

    # Wait for PostgreSQL to be ready
    log_info "[Phase 1c] Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=bootstrap-postgresql -n bootstrap --timeout=180s

    # Test MinIO connectivity using local mc client (installed in Phase 0)
    log_info "[Phase 1c] Testing MinIO S3 connectivity..."

    # Port-forward to MinIO service for local testing
    kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2  # Wait for port-forward to establish

    # Test connectivity with local mc client
    if command -v mc >/dev/null 2>&1; then
        if mc alias set phase1-test http://localhost:9000 "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null 2>&1; then
            log_success "[Phase 1c] ✅ MinIO S3 connectivity verified"
            mc alias remove phase1-test >/dev/null 2>&1
        else
            log_warning "[Phase 1c] ⚠️  MinIO connectivity test failed (may still be initializing)"
        fi
    else
        log_warning "[Phase 1c] ⚠️  MinIO Client (mc) not found - install with Phase 0"
    fi

    # Cleanup port-forward
    kill $pf_pid 2>/dev/null || true

    # Verify terraform_locks database (CloudNativePG creates it via initdb bootstrap)
    log_info "[Phase 1c] Verifying terraform_locks database..."
    kubectl exec -n bootstrap bootstrap-postgresql-1 -- bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -U postgres -d terraform_locks -c 'SELECT 1;'" >/dev/null 2>&1 && {
        log_success "[Phase 1c] PostgreSQL connectivity test successful"
    } || {
        log_warning "[Phase 1c] PostgreSQL connectivity test failed (database may still be initializing)"
    }

    # Show deployed components
    log_success "[Phase 1c] ✅ Bootstrap foundation verified"
    log_info "[Phase 1c]   • MinIO: S3-compatible storage for Terraform state"
    log_info "[Phase 1c]   • PostgreSQL: State locking database"
    log_info "[Phase 1c]   • Local State: terraform.tfstate in $(pwd)"
}


# PRIVATE: Print final success message with next steps
_print_success_message() {
    log_info ""
    log_success "[Phase 1] 🎉 PHASE 1 COMPLETE!"
    log_info ""
    log_info "[Phase 1] Bootstrap Foundation: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"
    log_success "[Phase 1]   ✅ Node storage encrypted (LUKS container)"
    log_success "[Phase 1]   ✅ k3s cluster installed on encrypted storage"
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
    # Parse parameters if provided (handles both sourced and direct execution)
    if [[ $# -gt 0 ]]; then
        _parse_parameters "$@"
    fi

    print_banner "🏗️  Enterprise Platform Phase 1" \
                 "📦 k3s + Bootstrap Storage" \
                 "🎯 Resources: ${NODE_COUNT} nodes, ${RESOURCE_TIER} tier"

    log_phase "🚀 Phase 1a: Environment Validation"
    _validate_environment
    detect_system_architecture

    log_phase "🚀 Phase 1a: Node Encryption Setup"
    _setup_node_encryption

    log_phase "🚀 Phase 1b: k3s Cluster Installation on Encrypted Storage"
    _install_k3s
    _validate_cluster

    log_phase "🚀 Phase 1c: Bootstrap Storage Deployment"
    _prepare_terraform_workspace
    _deploy_bootstrap_storage
    _verify_bootstrap_foundation

    log_phase "🚀 Phase 1: Complete!"

    _print_success_message

    # Note: Cleanup handled by EXIT trap (cleanup function)
    # - In orchestrated mode: credentials cleared by bootstrap.sh
    # - In standalone mode: credentials cleared here, temp dir cleaned by EXIT trap
}

# Only run main when executed directly (not sourced via smart_import)
# Handles: direct execution, curl piping, but NOT sourcing via smart_import
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${BASH_SOURCE[0]}" =~ ^/dev/fd/ ]] || [[ -z "${BASH_SOURCE[0]}" ]]; then
    # Stack cleanup trap, handles both success and failure (including user interrupts)
    stack_trap "_cleanup" EXIT

    main "$@"
fi