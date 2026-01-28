#!/bin/bash
set -euo pipefail

# Enterprise-Ready Platform Bootstrap - Phase 2
# State Migration + Flux GitOps Bootstrap
# Usage: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase2.sh | bash -s -- --nodes=1 --tier=small --environment=production [--skip-validation]

# PHASE 2 SUBPHASES:
#   2a. Prerequisites & Validation (verify Phase 1 dependencies)
#   2b. Bootstrap State Migration (LOCAL → remote MinIO)
#   2c. Flux GitOps Bootstrap (install Flux + create secrets + apply sync)
#   2d. Validation (wait for Flux sync + infrastructure ready)

# Configuration - set defaults before imports
GITHUB_ORG="${GITHUB_ORG:-antonioacg}"
GIT_REF="${GIT_REF:-main}"
DEPLOYMENTS_REF="${DEPLOYMENTS_REF:-main}"  # Separate ref for deployments repo
NODE_COUNT=1
RESOURCE_TIER="small"
ENVIRONMENT="production"
SKIP_VALIDATION=false
STOP_AFTER=""

# Required from Phase 0 - no defaults, must be set
FLUX_VERSION="${FLUX_VERSION:-}"

# Load import utility and logging library (bash 3.2+ compatible)
eval "$(curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG}/infra-management/${GIT_REF}/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"
smart_import "infra-management/scripts/lib/system.sh"
smart_import "infra-management/scripts/lib/network.sh"
smart_import "infra-management/scripts/lib/credentials.sh"
smart_import "infra-management/scripts/lib/minio.sh"

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
            --environment=*)
                ENVIRONMENT="${1#*=}"
                shift
                ;;
            --skip-validation)
                SKIP_VALIDATION=true
                shift
                ;;
            --stop-after=*)
                STOP_AFTER="${1#*=}"
                shift
                ;;
            --help|-h)
                echo "Enterprise Platform Bootstrap - Phase 2"
                echo "State Migration + Flux GitOps Bootstrap"
                echo ""
                echo "Usage:"
                echo "  curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase2.sh | bash -s -- [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --nodes=N            Number of nodes (default: 1)"
                echo "  --tier=SIZE          Resource tier: small|medium|large (default: small)"
                echo "  --environment=ENV    Environment name (default: production)"
                echo "  --skip-validation    Skip environment validation (when called from main bootstrap)"
                echo "  --stop-after=PHASE   Stop after specific subphase: 2a|2b|2c|2d"
                echo "  --help, -h           Show this help message"
                echo ""
                echo "Environment Variables:"
                echo "  LOG_LEVEL             Logging level: ERROR|WARN|INFO|DEBUG|TRACE (default: INFO)"
                echo "  GITHUB_TOKEN          GitHub token for Flux git authentication (required)"
                echo "  GITHUB_ORG            GitHub organization/user (default: antonioacg)"
                echo "  FLUX_VERSION          Flux version to install (from Phase 0, required)"
                echo "  DEPLOYMENTS_REF       Git ref for deployments repo (default: main)"
                echo ""
                exit 0
                ;;
            *)
                echo "Error: Unknown parameter: $1"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo "  --nodes=N            Number of nodes (default: 1)"
                echo "  --tier=SIZE          Resource tier: small|medium|large (default: small)"
                echo "  --environment=ENV    Environment name (default: production)"
                echo "  --skip-validation    Skip environment validation"
                echo "  --stop-after=PHASE   Stop after specific subphase: 2a|2b|2c|2d"
                echo "  --help, -h           Show this help message"
                echo ""
                exit 1
                ;;
        esac
    done
}

# Global variables for cleanup
MINIO_PF_PID=""

# PRIVATE: Cleanup function for Phase 2
_cleanup() {
    local exit_code=$?

    log_info "[Phase 2] Cleaning up resources..."

    # Kill port-forwards (phase-specific cleanup)
    if [[ -n "$MINIO_PF_PID" ]]; then
        kill "$MINIO_PF_PID" 2>/dev/null || true
        log_info "[Phase 2] Stopped MinIO port-forward (PID: $MINIO_PF_PID)"
    fi

    # Clean shared temp directory (idempotent)
    rm -rf "$BOOTSTRAP_TEMP_DIR" 2>/dev/null || true

    # Show appropriate message based on exit code
    if [[ $exit_code -eq 130 ]]; then
        log_warning "[Phase 2] Script interrupted by user"
    elif [[ $exit_code -ne 0 ]]; then
        log_error "[Phase 2] Phase 2 failed with exit code $exit_code"
        log_info "[Phase 2] Check logs above for specific error details"
    fi
}

# PRIVATE: Validate Phase 1 dependencies and credentials
_validate_phase2_prerequisites() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        log_info "[Phase 2a] Skipping validation (orchestrated mode)"
        return
    fi

    log_info "[Phase 2a] Validating Phase 0 and Phase 1 dependencies..."

    # Check required Phase 0 configuration (no defaults allowed)
    if [[ -z "${FLUX_VERSION:-}" ]]; then
        log_error "[Phase 2a] FLUX_VERSION environment variable is required"
        log_error "[Phase 2a] This should be set by Phase 0"
        exit 1
    fi

    log_success "[Phase 2a] Phase 0 configuration validated (Flux v${FLUX_VERSION})"

    # Check required credentials from Phase 1
    if [[ -z "${TF_VAR_minio_root_user:-}" || -z "${TF_VAR_minio_root_password:-}" || -z "${TF_VAR_postgres_password:-}" ]]; then
        log_error "[Phase 2a] Required Phase 1 credentials missing"
        log_info ""
        log_info "Required environment variables:"
        log_info "  - TF_VAR_minio_root_user (from Phase 1)"
        log_info "  - TF_VAR_minio_root_password (from Phase 1)"
        log_info "  - TF_VAR_postgres_password (from Phase 1)"
        log_info ""
        log_info "These are generated by Phase 1"
        exit 1
    fi

    # Check GITHUB_TOKEN for Flux
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        log_error "[Phase 2a] GITHUB_TOKEN required for Flux git authentication"
        exit 1
    fi

    # Check Phase 1 infrastructure is running
    if ! kubectl get svc -n storage minio &>/dev/null; then
        log_error "[Phase 2a] MinIO service not found in storage namespace"
        log_info "Run Phase 1 first: bootstrap-phase1.sh"
        exit 1
    fi

    if ! kubectl get svc -n databases postgresql-rw &>/dev/null; then
        log_error "[Phase 2a] PostgreSQL service not found in databases namespace"
        log_info "Run Phase 1 first: bootstrap-phase1.sh"
        exit 1
    fi

    log_success "[Phase 2a] Phase 1 dependencies validated"
}

# PRIVATE: Set up bootstrap working directory and migrate state
_migrate_bootstrap_state() {
    log_info "[Phase 2b] Setting up bootstrap state migration..."

    # Set up working directory
    if [[ "${USE_LOCAL_IMPORTS:-false}" == "true" ]]; then
        # Local mode: use actual bootstrap-state directory
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        BOOTSTRAP_STATE_DIR="$(dirname "$SCRIPT_DIR")/bootstrap-state"
    else
        # Remote mode: use shared bootstrap temp directory
        BOOTSTRAP_STATE_DIR="${BOOTSTRAP_TEMP_DIR:-/tmp/bootstrap-state}"

        # Verify state directory exists
        if [[ ! -d "$BOOTSTRAP_STATE_DIR" ]]; then
            log_error "[Phase 2b] Bootstrap state directory not found: $BOOTSTRAP_STATE_DIR"
            log_error "[Phase 2b] Phase 1 must run before Phase 2"
            exit 1
        fi

        if [[ ! -f "$BOOTSTRAP_STATE_DIR/terraform.tfstate" ]]; then
            log_error "[Phase 2b] terraform.tfstate not found in $BOOTSTRAP_STATE_DIR"
            exit 1
        fi

        log_success "[Phase 2b] Using Phase 1 state: $BOOTSTRAP_STATE_DIR"
    fi

    cd "$BOOTSTRAP_STATE_DIR"

    # Only migrate if we have local state (not already migrated)
    if [[ -f "terraform.tfstate" && -s "terraform.tfstate" ]]; then
        log_info "[Phase 2b] Found local state, performing migration..."

        # Backup local state and backend config
        cp terraform.tfstate "terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)"
        cp backend.tf "backend.tf.backup.$(date +%Y%m%d_%H%M%S)"

        # Update backend.tf to use S3 backend for migration
        log_info "[Phase 2b] Updating backend configuration to S3..."
        cat > backend.tf <<'EOF'
# Bootstrap State Backend Configuration
# Migrated to remote S3 backend (MinIO)

terraform {
  # Remote S3 backend (MinIO) - partial configuration
  # Full config provided via backend-remote.hcl + runtime flags
  backend "s3" {
  }
}
EOF

        # Port-forward to MinIO for migration
        log_info "[Phase 2b] Starting port-forward to MinIO..."
        kubectl port-forward -n storage svc/minio 9000:9000 &>/dev/null &
        MINIO_PF_PID=$!
        sleep 5

        # Test connectivity
        if ! curl -s "http://localhost:9000/minio/health/ready" &>/dev/null; then
            log_error "[Phase 2b] Cannot connect to MinIO for migration"
            exit 1
        fi

        # Set AWS credentials for S3 backend (MinIO compatibility)
        export AWS_ACCESS_KEY_ID="$TF_VAR_minio_root_user"
        export AWS_SECRET_ACCESS_KEY="$TF_VAR_minio_root_password"

        log_debug "[Phase 2b] Credentials configured for state migration"

        if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
            log_error "[Phase 2b] Credentials missing!"
            exit 1
        fi

        # Migrate state using backend-config file + runtime overrides
        log_info "[Phase 2b] Migrating state to remote backend..."
        terraform init -migrate-state \
            -backend-config=backend-remote.hcl \
            -backend-config="key=${ENVIRONMENT}/bootstrap/terraform.tfstate" \
            -backend-config="endpoint=http://localhost:9000" \
            -force-copy

        # Verify migration
        if terraform state list &>/dev/null; then
            log_success "[Phase 2b] State migration completed successfully"
        else
            log_error "[Phase 2b] State migration verification failed"
            exit 1
        fi
    else
        log_info "[Phase 2b] No local state found, initializing with remote backend..."
        terraform init -backend-config=backend-remote.hcl
    fi
}

# ============================================================================
# PHASE 2c: Flux GitOps Bootstrap
# ============================================================================

# PRIVATE: Install Flux controllers
_install_flux_controllers() {
    log_info "[Phase 2c] Installing Flux controllers v${FLUX_VERSION}..."

    if ! flux install --version="v${FLUX_VERSION}"; then
        log_error "[Phase 2c] Failed to install Flux controllers"
        log_info "[Phase 2c] Check: flux check"
        exit 1
    fi

    # Wait for controllers to be ready
    log_info "[Phase 2c] Waiting for Flux controllers to be ready..."
    if ! flux check; then
        log_error "[Phase 2c] Flux controllers not ready"
        exit 1
    fi

    log_success "[Phase 2c] Flux controllers v${FLUX_VERSION} installed"
}

# PRIVATE: Create Flux git authentication secret
_create_flux_git_secret() {
    log_info "[Phase 2c] Creating Flux git authentication secret..."

    kubectl create secret generic flux-git-auth \
        --namespace=flux-system \
        --from-literal=username=git \
        --from-literal=password="${GITHUB_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_success "[Phase 2c] Flux git authentication secret created"
}

# PRIVATE: Create Flux GitRepository and Kustomization
_create_flux_sync() {
    log_info "[Phase 2c] Creating Flux sync configuration..."
    log_info "[Phase 2c]   Repository: https://github.com/${GITHUB_ORG}/deployments"
    log_info "[Phase 2c]   Branch: ${DEPLOYMENTS_REF}"
    log_info "[Phase 2c]   Path: clusters/${ENVIRONMENT}"

    # Create GitRepository
    if ! flux create source git flux-system \
        --url="https://github.com/${GITHUB_ORG}/deployments" \
        --branch="${DEPLOYMENTS_REF}" \
        --secret-ref=flux-git-auth \
        --interval=1m; then
        log_error "[Phase 2c] Failed to create GitRepository"
        exit 1
    fi

    # Create Kustomization (don't wait - Phase 2d handles validation)
    if ! flux create kustomization flux-system \
        --source=GitRepository/flux-system \
        --path="clusters/${ENVIRONMENT}" \
        --prune=true \
        --interval=10m; then
        log_error "[Phase 2c] Failed to create Kustomization"
        exit 1
    fi

    log_success "[Phase 2c] Flux sync configuration created"
}

# PRIVATE: Create Vault storage credentials secret
# Uses the dedicated vault-user credentials (least privilege: vault-storage bucket only)
# Note: tf-controller gets its credentials via ExternalSecret after Vault is ready
_create_vault_storage_secret() {
    log_info "[Phase 2c] Creating Vault storage credentials secret..."

    # Create vault namespace
    kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

    # Copy vault-minio-credentials from minio namespace to vault namespace
    # These credentials were created by _create_minio_users with access to vault-storage bucket only
    # Keys are prefixed with AWS_ by Bank-Vaults credentialsConfig (env: AWS_)
    # So ACCESS_KEY_ID becomes AWS_ACCESS_KEY_ID, SECRET_ACCESS_KEY becomes AWS_SECRET_ACCESS_KEY
    if [[ -n "${VAULT_MINIO_ACCESS_KEY:-}" && -n "${VAULT_MINIO_SECRET_KEY:-}" ]]; then
        kubectl create secret generic vault-storage-credentials \
            --namespace=vault \
            --from-literal=ACCESS_KEY_ID="${VAULT_MINIO_ACCESS_KEY}" \
            --from-literal=SECRET_ACCESS_KEY="${VAULT_MINIO_SECRET_KEY}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log_success "[Phase 2c] Vault storage credentials secret created (using vault-user)"
    else
        # Fallback to root credentials if vault-user not available (backwards compatibility)
        log_warning "[Phase 2c] vault-user credentials not found, using root credentials"
        kubectl create secret generic vault-storage-credentials \
            --namespace=vault \
            --from-literal=ACCESS_KEY_ID="${TF_VAR_minio_root_user}" \
            --from-literal=SECRET_ACCESS_KEY="${TF_VAR_minio_root_password}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log_success "[Phase 2c] Vault storage credentials secret created (using root)"
    fi
}


# ============================================================================
# PHASE 2d: Validation
# ============================================================================

# PRIVATE: Wait for Flux to sync
_wait_for_flux_sync() {
    log_info "[Phase 2d] Waiting for Flux to sync..."

    # Wait for GitRepository to be ready
    log_info "[Phase 2d] Waiting for GitRepository to be ready..."
    if ! kubectl -n flux-system wait --for=condition=Ready gitrepository/flux-system --timeout=300s; then
        log_error "[Phase 2d] GitRepository failed to sync"
        log_info "[Phase 2d] Check: flux get sources git"
        exit 1
    fi

    # Wait for root Kustomization to be ready
    log_info "[Phase 2d] Waiting for root Kustomization to be ready..."
    if ! kubectl -n flux-system wait --for=condition=Ready kustomization/flux-system --timeout=600s; then
        log_error "[Phase 2d] Root Kustomization failed to reconcile"
        log_info "[Phase 2d] Check: flux get kustomizations"
        exit 1
    fi

    log_success "[Phase 2d] Flux sync completed"
}

# PRIVATE: Validate Vault is ready
_validate_vault_ready() {
    log_info "[Phase 2d] Validating Vault deployment..."

    # Wait for vault-operator
    log_info "[Phase 2d] Waiting for Bank-Vaults operator..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault-operator -n vault-operator --timeout=300s 2>/dev/null; then
        log_warning "[Phase 2d] Bank-Vaults operator pods not found or not ready"
        log_info "[Phase 2d] This may be normal if Flux is still reconciling"
    else
        log_success "[Phase 2d] Bank-Vaults operator is ready"
    fi

    # Wait for Vault
    log_info "[Phase 2d] Waiting for Vault to be ready..."
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault -n vault --timeout=600s 2>/dev/null; then
        log_warning "[Phase 2d] Vault pods not found or not ready"
        log_info "[Phase 2d] Check: kubectl get pods -n vault"
    else
        log_success "[Phase 2d] Vault is ready"
    fi

    # Check for unseal keys
    log_info "[Phase 2d] Checking for Vault unseal keys..."
    if kubectl get secret vault-unseal-keys -n vault &>/dev/null; then
        log_success "[Phase 2d] Vault unseal keys secret exists"
    else
        log_warning "[Phase 2d] Vault unseal keys not found yet"
        log_info "[Phase 2d] Bank-Vaults will create these during initialization"
    fi
}

# PRIVATE: Validate External Secrets is ready
_validate_external_secrets_ready() {
    log_info "[Phase 2d] Validating External Secrets deployment..."

    # Wait for External Secrets operator
    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=external-secrets -n external-secrets-system --timeout=300s 2>/dev/null; then
        log_warning "[Phase 2d] External Secrets pods not found or not ready"
        log_info "[Phase 2d] Check: kubectl get pods -n external-secrets-system"
    else
        log_success "[Phase 2d] External Secrets operator is ready"
    fi

    # Check ClusterSecretStore
    if kubectl get clustersecretstore vault-backend &>/dev/null; then
        log_success "[Phase 2d] ClusterSecretStore vault-backend exists"
    else
        log_warning "[Phase 2d] ClusterSecretStore not found yet"
        log_info "[Phase 2d] This will be created by Flux"
    fi
}

# PRIVATE: Store GitHub token in Vault for ExternalSecret sync
_store_github_token_in_vault() {
    log_info "[Phase 2d] Storing GitHub token in Vault for ExternalSecret sync..."

    # Check if Vault is ready and we have the root token
    local vault_pod
    vault_pod=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$vault_pod" ]]; then
        log_warning "[Phase 2d] Vault pod not found, skipping token storage"
        return 0
    fi

    # Get root token from vault-unseal-keys secret (created by Bank-Vaults)
    local vault_token
    vault_token=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "$vault_token" ]]; then
        log_warning "[Phase 2d] Vault root token not found in secret, cannot store GitHub token"
        log_info "[Phase 2d] Manual action: vault kv put secret/flux/git-auth username=git password=${GITHUB_TOKEN:0:4}..."
        return 0
    fi

    # Store GitHub token in Vault using kubectl exec
    if kubectl exec -n vault "$vault_pod" -- \
        VAULT_TOKEN="$vault_token" \
        vault kv put secret/flux/git-auth username=git "password=${GITHUB_TOKEN}" &>/dev/null; then
        log_success "[Phase 2d] GitHub token stored in Vault at secret/data/flux/git-auth"
    else
        log_warning "[Phase 2d] Failed to store GitHub token in Vault"
        log_info "[Phase 2d] Manual action: kubectl exec -n vault <vault-pod> -- VAULT_TOKEN=<token> vault kv put secret/flux/git-auth username=git password=<token>"
    fi
}

# PRIVATE: Write bootstrap inputs to Vault
_write_bootstrap_inputs_to_vault() {
    log_info "[Phase 2d] Writing bootstrap inputs to Vault..."

    local vault_pod vault_token vault_args

    vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$vault_pod" ]]; then
        log_warning "[Phase 2d] Vault pod not found, skipping inputs storage"
        return 0
    fi

    vault_token=$(kubectl get secret vault-unseal-keys -n vault \
        -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "$vault_token" ]]; then
        log_warning "[Phase 2d] Vault root token not found, skipping inputs storage"
        return 0
    fi

    vault_args=$(_collect_vault_input_secrets)

    if [[ -n "$vault_args" ]]; then
        log_info "Writing env vars matching VAULT_INPUT_* to secret/bootstrap/inputs..."
        if kubectl exec -n vault "$vault_pod" -- env \
            VAULT_TOKEN="$vault_token" \
            vault kv put secret/bootstrap/inputs $vault_args &>/dev/null; then
            log_success "[Phase 2d] Bootstrap inputs written to Vault"
        else
            log_warning "[Phase 2d] Failed to write bootstrap inputs to Vault"
        fi
    fi
}

# PRIVATE: Validate ingress-nginx is ready
_validate_ingress_ready() {
    log_info "[Phase 2d] Validating Nginx Ingress deployment..."

    if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=180s 2>/dev/null; then
        log_warning "[Phase 2d] Nginx Ingress pods not found or not ready"
        log_info "[Phase 2d] Check: kubectl get pods -n ingress-nginx"
    else
        log_success "[Phase 2d] Nginx Ingress is ready"
    fi
}

# PRIVATE: Show Flux status
_show_flux_status() {
    log_info "[Phase 2d] Current Flux status:"
    log_info ""
    log_info "Git Sources:"
    flux get sources git 2>/dev/null || log_warning "Could not get git sources"
    log_info ""
    log_info "Kustomizations:"
    flux get kustomizations 2>/dev/null || log_warning "Could not get kustomizations"
    log_info ""
    log_info "HelmReleases:"
    flux get helmreleases -A 2>/dev/null || log_warning "Could not get helmreleases"
}

# PRIVATE: Print success message with next steps
_print_success_message() {
    print_banner "Phase 2 Complete!" "State migration + Flux GitOps Bootstrap" "Environment: $ENVIRONMENT, Resources: $NODE_COUNT nodes, $RESOURCE_TIER tier"

    log_info ""
    log_info "What was deployed:"
    log_info "  - Bootstrap state migrated to remote MinIO backend"
    log_info "  - Flux GitOps controllers installed"
    log_info "  - Bank-Vaults Operator: Production-ready Vault lifecycle management"
    log_info "  - Vault: Secret management (auto-initialized and unsealed)"
    log_info "  - External Secrets: Kubernetes secret synchronization"
    log_info "  - Nginx Ingress: Load balancing and SSL termination"
    log_info ""
    log_info "GitOps is now managing infrastructure!"
    log_info ""
    log_info "Verify deployment:"
    log_info "  flux get sources git"
    log_info "  flux get kustomizations"
    log_info "  flux get helmreleases -A"
    log_info "  kubectl get pods -A"
    log_info ""
}

# Main function
main() {
    # Parse parameters if provided (handles both sourced and direct execution)
    if [[ $# -gt 0 ]]; then
        _parse_parameters "$@"
    fi

    print_banner "Phase 2: State Migration + Flux GitOps" "Remote-first enterprise deployment" "Environment: $ENVIRONMENT, Resources: $NODE_COUNT nodes, $RESOURCE_TIER tier"

    log_phase "Phase 2a: Prerequisites & Validation"
    _validate_phase2_prerequisites

    if [[ "$STOP_AFTER" == "2a" ]]; then
        log_success "Stopped after Phase 2a as requested"
        log_info "Prerequisites validated. Phase 1 dependencies confirmed."
        return 0
    fi

    log_phase "Phase 2b: Bootstrap State Migration + MinIO Users"
    _migrate_bootstrap_state
    _create_minio_users

    if [[ "$STOP_AFTER" == "2b" ]]; then
        log_success "Stopped after Phase 2b as requested"
        log_info "State migration completed. MinIO users created. Credentials preserved in memory."
        return 0
    fi

    log_phase "Phase 2c: Flux GitOps Bootstrap"
    _install_flux_controllers
    _create_flux_git_secret
    _create_vault_storage_secret
    _create_flux_sync

    if [[ "$STOP_AFTER" == "2c" ]]; then
        log_success "Stopped after Phase 2c as requested"
        log_info "Flux installed and sync applied. GitOps reconciliation in progress."
        return 0
    fi

    log_phase "Phase 2d: Validation"
    _wait_for_flux_sync
    _validate_vault_ready
    _write_bootstrap_inputs_to_vault

    # Store credentials in Vault (MUST succeed - credentials are in-memory only)
    _store_minio_creds_in_vault || {
        log_error "FATAL: Failed to store MinIO credentials in Vault"
        log_error "Credentials will be lost when script exits"
        exit 1
    }

    _store_postgres_creds_in_vault || {
        log_error "FATAL: Failed to store PostgreSQL credentials in Vault"
        log_error "Credentials will be lost when script exits"
        exit 1
    }

    _validate_external_secrets_ready
    _store_github_token_in_vault
    _validate_ingress_ready
    _show_flux_status

    if [[ "$STOP_AFTER" == "2d" ]]; then
        log_success "Stopped after Phase 2d as requested"
        log_info "Validation completed. Credentials preserved in memory."
        return 0
    fi

    _print_success_message
}

# Only run main when executed directly (not sourced via smart_import)
# Handles: direct execution, curl piping, but NOT sourcing via smart_import
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${BASH_SOURCE[0]}" =~ ^/dev/fd/ ]] || [[ -z "${BASH_SOURCE[0]}" ]]; then
    # Stack cleanup trap, handles both success and failure (including user interrupts)
    stack_trap "_cleanup" EXIT

    main "$@"
fi
