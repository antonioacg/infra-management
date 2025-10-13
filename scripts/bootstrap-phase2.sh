#!/bin/bash
set -euo pipefail

# Enterprise-Ready Platform Bootstrap - Phase 2
# State Migration + Infrastructure Deployment
# Usage: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase2.sh | bash -s -- --nodes=1 --tier=small --environment=production [--skip-validation]

# PHASE 2 SUBPHASES:
#   2a. Prerequisites & Validation (verify Phase 1 dependencies)
#   2b. Bootstrap State Migration (LOCAL → remote MinIO)
#   2c. Infrastructure Deployment (Vault + External Secrets + Networking)
#   2d. Validation & Cleanup

# Configuration - set defaults before imports
GITHUB_ORG="${GITHUB_ORG:-antonioacg}"
GIT_REF="${GIT_REF:-main}"
NODE_COUNT=1
RESOURCE_TIER="small"
ENVIRONMENT="production"
SKIP_VALIDATION=false
STOP_AFTER=""

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
                echo "State Migration + Infrastructure Deployment"
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
                echo "  LOG_LEVEL           Logging level: ERROR|WARN|INFO|DEBUG|TRACE (default: INFO)"
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

    log_info "🧹 [Phase 2] Cleaning up resources..."

    # Kill port-forwards (phase-specific cleanup)
    if [[ -n "$MINIO_PF_PID" ]]; then
        kill "$MINIO_PF_PID" 2>/dev/null || true
        log_info "[Phase 2] Stopped MinIO port-forward (PID: $MINIO_PF_PID)"
    fi

    # Clean shared temp directory (idempotent)
    rm -rf /tmp/bootstrap-state 2>/dev/null || true

    # Show appropriate message based on exit code
    if [[ $exit_code -eq 130 ]]; then
        log_warning "[Phase 2] ⚠️  Script interrupted by user"
    elif [[ $exit_code -ne 0 ]]; then
        log_error "[Phase 2] ❌ Phase 2 failed with exit code $exit_code"
        log_info "[Phase 2] 🔍 Check logs above for specific error details"
    fi
}

# PRIVATE: Validate Phase 1 dependencies and credentials
_validate_phase2_prerequisites() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        log_info "[Phase 2a] Skipping validation (orchestrated mode)"
        return
    fi

    log_info "[Phase 2a] Validating Phase 1 dependencies..."

    # Check required credentials from Phase 1
    if [[ -z "${TF_VAR_minio_root_user:-}" || -z "${TF_VAR_minio_root_password:-}" || -z "${TF_VAR_postgres_password:-}" ]]; then
        log_error "[Phase 2a] ❌ Required Phase 1 credentials missing"
        log_info ""
        log_info "Required environment variables:"
        log_info "  - TF_VAR_minio_root_user (from Phase 1)"
        log_info "  - TF_VAR_minio_root_password (from Phase 1)"
        log_info "  - TF_VAR_postgres_password (from Phase 1)"
        log_info ""
        log_info "These are generated by Phase 1"
        exit 1
    fi

    # Check Phase 1 infrastructure is running
    if ! kubectl get svc -n bootstrap bootstrap-minio &>/dev/null; then
        log_error "[Phase 2a] ❌ MinIO service not found in bootstrap namespace"
        log_info "Run Phase 1 first: bootstrap-phase1.sh"
        exit 1
    fi

    if ! kubectl get svc -n bootstrap bootstrap-postgresql &>/dev/null; then
        log_error "[Phase 2a] ❌ PostgreSQL service not found in bootstrap namespace"
        log_info "Run Phase 1 first: bootstrap-phase1.sh"
        exit 1
    fi

    log_success "[Phase 2a] ✅ Phase 1 dependencies validated"
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
            log_error "[Phase 2b] ❌ Bootstrap state directory not found: $BOOTSTRAP_STATE_DIR"
            log_error "[Phase 2b] Phase 1 must run before Phase 2"
            exit 1
        fi

        if [[ ! -f "$BOOTSTRAP_STATE_DIR/terraform.tfstate" ]]; then
            log_error "[Phase 2b] ❌ terraform.tfstate not found in $BOOTSTRAP_STATE_DIR"
            exit 1
        fi

        log_success "[Phase 2b] ✅ Using Phase 1 state: $BOOTSTRAP_STATE_DIR"
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
        kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 &>/dev/null &
        MINIO_PF_PID=$!
        sleep 5

        # Test connectivity
        if ! curl -s "http://localhost:9000/minio/health/ready" &>/dev/null; then
            log_error "[Phase 2b] ❌ Cannot connect to MinIO for migration"
            exit 1
        fi

        # Set AWS credentials for S3 backend (MinIO compatibility)
        export AWS_ACCESS_KEY_ID="$TF_VAR_minio_root_user"
        export AWS_SECRET_ACCESS_KEY="$TF_VAR_minio_root_password"

        # TESTING: Log full credentials for debugging
        log_info "[Phase 2b] TESTING - Full credentials:"
        log_info "[Phase 2b]   TF_VAR_minio_root_user=$TF_VAR_minio_root_user"
        log_info "[Phase 2b]   TF_VAR_minio_root_password=$TF_VAR_minio_root_password"
        log_info "[Phase 2b]   AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
        log_info "[Phase 2b]   AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY"

        if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
            log_error "[Phase 2b] ❌ Credentials missing!"
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
            log_success "[Phase 2b] ✅ State migration completed successfully"
        else
            log_error "[Phase 2b] ❌ State migration verification failed"
            exit 1
        fi
    else
        log_info "[Phase 2b] No local state found, initializing with remote backend..."
        terraform init -backend-config=backend-remote.hcl
    fi
}

# PRIVATE: Set up infrastructure workspace with remote modules
_setup_infrastructure_workspace() {
    log_info "[Phase 2c] Setting up infrastructure workspace..."

    # Infrastructure working directory (under bootstrap temp dir)
    INFRA_DIR="${BOOTSTRAP_TEMP_DIR}/infra"

    # Clone infrastructure repository if not already a git repo
    if [[ -d "$INFRA_DIR/.git" ]]; then
        log_info "[Phase 2c] Using existing infrastructure repository..."
        cd "$INFRA_DIR" || exit 1
    else
        # Remove any non-git directory that might exist
        if [[ -d "$INFRA_DIR" ]]; then
            log_warning "[Phase 2c] Removing non-git directory at $INFRA_DIR"
            rm -rf "$INFRA_DIR"
        fi

        log_info "[Phase 2c] Cloning infrastructure repository..."
        if ! git clone "https://github.com/${GITHUB_ORG}/infra.git" "$INFRA_DIR"; then
            log_error "[Phase 2c] ❌ Failed to clone infrastructure repository"
            log_info "[Phase 2c] Repository: https://github.com/${GITHUB_ORG}/infra.git"
            exit 1
        fi
        cd "$INFRA_DIR" || exit 1
    fi

    # Checkout specific ref (branch or commit SHA)
    log_info "[Phase 2c] Checking out ref: ${GIT_REF}..."
    if ! git fetch origin "${GIT_REF}" 2>/dev/null; then
        log_debug "[Phase 2c] Could not fetch ref ${GIT_REF}, trying direct checkout..."
    fi

    if ! git checkout "${GIT_REF}"; then
        log_error "[Phase 2c] ❌ Failed to checkout ref: ${GIT_REF}"
        log_info "[Phase 2c] Available branches: $(git branch -r | head -5)"
        exit 1
    fi

    # Verify environment directory exists
    if [[ ! -d "environments/${ENVIRONMENT}" ]]; then
        log_error "[Phase 2c] ❌ Environment directory not found: environments/${ENVIRONMENT}"
        log_info "[Phase 2c] Available environments: $(ls -1 environments 2>/dev/null | tr '\n' ' ')"
        exit 1
    fi

    # Navigate to environment directory
    cd "environments/${ENVIRONMENT}" || {
        log_error "[Phase 2c] ❌ Failed to navigate to environment directory"
        exit 1
    }

    # Set up backend credentials via environment variables
    log_info "[Phase 2c] Configuring backend credentials..."
    export AWS_ACCESS_KEY_ID="$TF_VAR_minio_root_user"
    export AWS_SECRET_ACCESS_KEY="$TF_VAR_minio_root_password"

    # Initialize with infrastructure backend
    log_info "[Phase 2c] Initializing Terraform with remote backend..."
    if ! terraform init -backend-config="key=${ENVIRONMENT}/infra/terraform.tfstate"; then
        log_error "[Phase 2c] ❌ Terraform initialization failed"
        log_info "[Phase 2c] Check MinIO port-forward: kubectl get svc -n bootstrap bootstrap-minio"
        log_info "[Phase 2c] Check backend.tf configuration in $(pwd)"
        exit 1
    fi

    log_success "[Phase 2c] ✅ Infrastructure workspace ready"
}

# PRIVATE: Deploy infrastructure components
_deploy_infrastructure() {
    log_info "[Phase 2c] Deploying infrastructure components..."

    # Ensure we're in environment directory (set by _setup_infrastructure_workspace)
    cd "$INFRA_DIR/environments/${ENVIRONMENT}" || {
        log_error "[Phase 2c] ❌ Failed to navigate to environment directory"
        log_info "[Phase 2c] INFRA_DIR: $INFRA_DIR"
        log_info "[Phase 2c] ENVIRONMENT: $ENVIRONMENT"
        exit 1
    }

    # Set environment variables for Terraform
    export TF_VAR_environment="$ENVIRONMENT"
    export TF_VAR_vault_storage_access_key="$TF_VAR_minio_root_user"
    export TF_VAR_vault_storage_secret_key="$TF_VAR_minio_root_password"
    export TF_VAR_github_org="$GITHUB_ORG"
    export TF_VAR_git_ref="$GIT_REF"

    # Ensure MinIO port-forward is still active
    if [[ -z "$MINIO_PF_PID" ]] || ! kill -0 "$MINIO_PF_PID" 2>/dev/null; then
        log_info "[Phase 2c] Restarting MinIO port-forward..."
        kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 &>/dev/null &
        MINIO_PF_PID=$!
        sleep 5
    fi

    # Retry terraform apply to handle transient network errors (helm chart downloads)
    local max_attempts=3
    local attempt=1
    local apply_success=false

    while [[ $attempt -le $max_attempts ]]; do
        local plan_file="tfplan-attempt${attempt}"

        if [[ $attempt -gt 1 ]]; then
            log_warning "[Phase 2c] Retry attempt $attempt/$max_attempts after previous failure..."
            sleep 5
        fi

        log_info "[Phase 2c] Creating plan: $plan_file"
        if ! terraform plan -out="$plan_file"; then
            log_error "[Phase 2c] Terraform plan failed on attempt $attempt"
            rm -f "$plan_file"
            if [[ $attempt -eq $max_attempts ]]; then
                log_error "[Phase 2c] ❌ Terraform plan failed after $max_attempts attempts"
                log_info "[Phase 2c] Current directory: $(pwd)"
                log_info "[Phase 2c] Files: $(ls -la *.tf 2>/dev/null || echo 'No .tf files found')"
                return 1
            fi
            ((attempt++))
            continue
        fi

        log_info "[Phase 2c] Applying plan: $plan_file (attempt $attempt/$max_attempts)"
        if terraform apply "$plan_file"; then
            apply_success=true
            # Clean up plan files after successful apply
            rm -f tfplan-attempt*
            break
        else
            log_warning "[Phase 2c] Terraform apply failed on attempt $attempt"
            if [[ $attempt -eq $max_attempts ]]; then
                log_error "[Phase 2c] ❌ Terraform apply failed after $max_attempts attempts"
                rm -f tfplan-attempt*
                return 1
            fi
            ((attempt++))
        fi
    done

    if [[ "$apply_success" == "true" ]]; then
        log_success "[Phase 2c] ✅ Infrastructure deployment completed"
        return 0
    else
        log_error "[Phase 2c] ❌ Infrastructure deployment failed"
        return 1
    fi
}

# PRIVATE: Wait for infrastructure services to be ready
_validate_infrastructure_deployment() {
    log_info "[Phase 2d] Validating infrastructure deployment..."

    # Wait for Bank-Vaults operator
    log_info "[Phase 2d] Waiting for Bank-Vaults operator to be ready..."
    if kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault-operator -n vault-operator --timeout=180s; then
        log_success "[Phase 2d] ✅ Bank-Vaults operator is ready"
    else
        log_error "[Phase 2d] ❌ Bank-Vaults operator failed to become ready"
        exit 1
    fi

    # Wait for Vault (managed by Bank-Vaults operator)
    log_info "[Phase 2d] Waiting for Vault to be ready..."
    if kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault -n vault --timeout=600s; then
        log_success "[Phase 2d] ✅ Vault is ready"
    else
        log_error "[Phase 2d] ❌ Vault failed to become ready"
        log_info "[Phase 2d] Check Bank-Vaults operator logs: kubectl logs -n vault-operator -l app.kubernetes.io/name=vault-operator"
        exit 1
    fi

    # Verify Vault unseal keys secret created by Bank-Vaults
    log_info "[Phase 2d] Verifying Vault unseal keys secret..."
    if kubectl get secret vault-unseal-keys -n vault >/dev/null 2>&1; then
        log_success "[Phase 2d] ✅ Vault unseal keys secret exists"
    else
        log_error "[Phase 2d] ❌ Vault unseal keys secret not found"
        log_info "[Phase 2d] Bank-Vaults should automatically create this during Vault initialization"
        exit 1
    fi

    # Wait for External Secrets
    log_info "[Phase 2d] Waiting for External Secrets to be ready..."
    if kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=external-secrets -n external-secrets-system --timeout=180s; then
        log_success "[Phase 2d] ✅ External Secrets is ready"
    else
        log_error "[Phase 2d] ❌ External Secrets failed to become ready"
        exit 1
    fi

    # Wait for Nginx Ingress
    log_info "[Phase 2d] Waiting for Nginx Ingress to be ready..."
    if kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=180s; then
        log_success "[Phase 2d] ✅ Nginx Ingress is ready"
    else
        log_error "[Phase 2d] ❌ Nginx Ingress failed to become ready"
        exit 1
    fi

    log_success "[Phase 2d] ✅ All infrastructure services are ready"
}

# PRIVATE: Print success message with next steps
_print_success_message() {
    print_banner "🎉 Phase 2 Complete!" "State migration + Infrastructure deployment" "Environment: $ENVIRONMENT, Resources: $NODE_COUNT nodes, $RESOURCE_TIER tier"

    log_info ""
    log_info "📋 What was deployed:"
    log_info "  • Bootstrap state migrated to remote MinIO backend"
    log_info "  • Bank-Vaults Operator: Production-ready Vault lifecycle management"
    log_info "  • Vault: Secret management (auto-initialized and unsealed)"
    log_info "  • External Secrets: Kubernetes secret synchronization"
    log_info "  • Nginx Ingress: Load balancing and SSL termination"
    log_info ""
    log_info "🔄 Next steps:"
    log_info "  • Phase 3: Advanced Vault policies and security configuration"
    log_info "  • Phase 4: GitOps activation with Flux"
    log_info ""
    log_info "🔍 Verify deployment:"
    log_info "  kubectl get pods -A"
    log_info "  kubectl get svc -A"
    log_info ""
}

# Main function
main() {
    # Parse parameters if provided (handles both sourced and direct execution)
    if [[ $# -gt 0 ]]; then
        _parse_parameters "$@"
    fi

    print_banner "🚀 Phase 2: State Migration + Infrastructure" "Remote-first enterprise deployment" "Environment: $ENVIRONMENT, Resources: $NODE_COUNT nodes, $RESOURCE_TIER tier"

    log_phase "🚀 Phase 2a: Prerequisites & Validation"
    _validate_phase2_prerequisites

    if [[ "$STOP_AFTER" == "2a" ]]; then
        log_success "✅ Stopped after Phase 2a as requested"
        log_info "Prerequisites validated. Phase 1 dependencies confirmed."
        return 0
    fi

    log_phase "🚀 Phase 2b: Bootstrap State Migration"
    _migrate_bootstrap_state

    if [[ "$STOP_AFTER" == "2b" ]]; then
        log_success "✅ Stopped after Phase 2b as requested"
        log_info "State migration completed. Credentials preserved in memory."
        return 0
    fi

    log_phase "🚀 Phase 2c: Infrastructure Deployment"
    _setup_infrastructure_workspace
    _deploy_infrastructure

    if [[ "$STOP_AFTER" == "2c" ]]; then
        log_success "✅ Stopped after Phase 2c as requested"
        log_info "Infrastructure deployed. Credentials preserved in memory."
        return 0
    fi

    log_phase "🚀 Phase 2d: Validation & Cleanup"
    _validate_infrastructure_deployment

    if [[ "$STOP_AFTER" == "2d" ]]; then
        log_success "✅ Stopped after Phase 2d as requested"
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