#!/bin/bash
set -euo pipefail

# Enterprise-Ready Platform Bootstrap - Phase 2
# State Migration + Infrastructure Deployment
# Usage: curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase2.sh | bash -s -- --nodes=1 --tier=small --environment=production [--skip-validation]

# PHASE 2 SUBPHASES:
#   2a. Bootstrap State Migration (LOCAL → remote MinIO)
#   2b. Infrastructure Repository Setup (remote modules)
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
    if [[ -z "${TF_VAR_minio_access_key:-}" || -z "${TF_VAR_minio_secret_key:-}" || -z "${TF_VAR_postgres_password:-}" ]]; then
        log_error "[Phase 2a] ❌ Required Phase 1 credentials missing"
        log_info ""
        log_info "Required environment variables:"
        log_info "  - TF_VAR_minio_access_key (from Phase 1)"
        log_info "  - TF_VAR_minio_secret_key (from Phase 1)"
        log_info "  - TF_VAR_postgres_password (from Phase 1)"
        log_info ""
        log_info "These are generated by Phase 1 when run with --preserve-state"
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
    log_info "[Phase 2a] Setting up bootstrap state migration..."

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
            log_error "[Phase 2a] ❌ Bootstrap state directory not found: $BOOTSTRAP_STATE_DIR"
            log_error "[Phase 2a] Phase 1 must run before Phase 2"
            exit 1
        fi

        if [[ ! -f "$BOOTSTRAP_STATE_DIR/terraform.tfstate" ]]; then
            log_error "[Phase 2a] ❌ terraform.tfstate not found in $BOOTSTRAP_STATE_DIR"
            exit 1
        fi

        log_success "[Phase 2a] ✅ Using Phase 1 state: $BOOTSTRAP_STATE_DIR"
    fi

    cd "$BOOTSTRAP_STATE_DIR"

    # Only migrate if we have local state (not already migrated)
    if [[ -f "terraform.tfstate" && -s "terraform.tfstate" ]]; then
        log_info "[Phase 2a] Found local state, performing migration..."

        # Backup local state and backend config
        cp terraform.tfstate "terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)"
        cp backend.tf "backend.tf.backup.$(date +%Y%m%d_%H%M%S)"

        # Update backend.tf to use S3 backend for migration
        log_info "[Phase 2a] Updating backend configuration to S3..."
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
        log_info "[Phase 2a] Starting port-forward to MinIO..."
        kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 &>/dev/null &
        MINIO_PF_PID=$!
        sleep 5

        # Test connectivity
        if ! curl -s "http://localhost:9000/minio/health/ready" &>/dev/null; then
            log_error "[Phase 2a] ❌ Cannot connect to MinIO for migration"
            exit 1
        fi

        # Set AWS credentials for S3 backend (MinIO compatibility)
        export AWS_ACCESS_KEY_ID="$TF_VAR_minio_access_key"
        export AWS_SECRET_ACCESS_KEY="$TF_VAR_minio_secret_key"

        # Log credential status (not the actual values)
        if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]]; then
            log_info "[Phase 2a] Credentials configured: access_key=${AWS_ACCESS_KEY_ID:0:8}..., secret_key=${AWS_SECRET_ACCESS_KEY:0:8}..."
        else
            log_error "[Phase 2a] ❌ Credentials missing: AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-EMPTY}, AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-EMPTY}"
            exit 1
        fi

        # Migrate state using backend-config file + runtime overrides
        log_info "[Phase 2a] Migrating state to remote backend..."
        terraform init -migrate-state \
            -backend-config=backend-remote.hcl \
            -backend-config="key=${ENVIRONMENT}/bootstrap/terraform.tfstate" \
            -backend-config="endpoint=http://localhost:9000" \
            -force-copy

        # Verify migration
        if terraform state list &>/dev/null; then
            log_success "[Phase 2a] ✅ State migration completed successfully"
        else
            log_error "[Phase 2a] ❌ State migration verification failed"
            exit 1
        fi
    else
        log_info "[Phase 2a] No local state found, initializing with remote backend..."
        terraform init -backend-config=backend-remote.hcl
    fi
}

# PRIVATE: Set up infrastructure workspace with remote modules
_setup_infrastructure_workspace() {
    log_info "[Phase 2b] Setting up infrastructure workspace..."

    # Create infrastructure working directory
    INFRA_DIR="/tmp/phase2-infra-$$"
    mkdir -p "$INFRA_DIR"
    cd "$INFRA_DIR"

    # Initialize with remote infrastructure modules
    log_info "[Phase 2b] Initializing infrastructure modules..."
    terraform init -from-module="github.com/${GITHUB_ORG}/infra//environments/${ENVIRONMENT}?ref=${GIT_REF}"

    # Set up backend credentials via environment variables
    log_info "[Phase 2b] Configuring backend credentials..."
    export AWS_ACCESS_KEY_ID="$TF_VAR_minio_access_key"
    export AWS_SECRET_ACCESS_KEY="$TF_VAR_minio_secret_key"

    # Initialize with infrastructure backend (uses existing backend.tf)
    terraform init -backend-config="key=${ENVIRONMENT}/infra/terraform.tfstate"

    log_success "[Phase 2b] ✅ Infrastructure workspace ready"
}

# PRIVATE: Deploy infrastructure components
_deploy_infrastructure() {
    log_info "[Phase 2c] Deploying infrastructure components..."

    # Ensure we're in infrastructure directory
    cd "$INFRA_DIR"

    # Set environment variables for Terraform
    export TF_VAR_environment="$ENVIRONMENT"
    export TF_VAR_vault_storage_access_key="$TF_VAR_minio_access_key"
    export TF_VAR_vault_storage_secret_key="$TF_VAR_minio_secret_key"
    export TF_VAR_github_org="$GITHUB_ORG"
    export TF_VAR_git_ref="$GIT_REF"

    # Ensure MinIO port-forward is still active
    if [[ -z "$MINIO_PF_PID" ]] || ! kill -0 "$MINIO_PF_PID" 2>/dev/null; then
        log_info "[Phase 2c] Restarting MinIO port-forward..."
        kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 &>/dev/null &
        MINIO_PF_PID=$!
        sleep 5
    fi

    # Plan and apply infrastructure
    log_info "[Phase 2c] Planning infrastructure deployment..."
    terraform plan -out=tfplan

    log_info "[Phase 2c] Applying infrastructure deployment..."
    terraform apply tfplan
    rm -f tfplan

    log_success "[Phase 2c] ✅ Infrastructure deployment completed"
}

# PRIVATE: Wait for infrastructure services to be ready
_validate_infrastructure_deployment() {
    log_info "[Phase 2d] Validating infrastructure deployment..."

    # Wait for Vault
    log_info "[Phase 2d] Waiting for Vault to be ready..."
    if kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s; then
        log_success "[Phase 2d] ✅ Vault is ready"
    else
        log_error "[Phase 2d] ❌ Vault failed to become ready"
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
    log_info "  • Vault: Secret management and storage"
    log_info "  • External Secrets: Kubernetes secret synchronization"
    log_info "  • Nginx Ingress: Load balancing and SSL termination"
    log_info ""
    log_info "🔄 Next steps:"
    log_info "  • Phase 3: Vault initialization and security policies"
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

    log_phase "🚀 Phase 2a: Prerequisites & State Migration"
    _validate_phase2_prerequisites
    _migrate_bootstrap_state

    if [[ "$STOP_AFTER" == "2a" ]]; then
        log_success "✅ Stopped after Phase 2a as requested"
        log_info "State migration completed. Credentials preserved in memory."
        return 0
    fi

    log_phase "🚀 Phase 2b: Infrastructure Workspace Setup"
    _setup_infrastructure_workspace

    if [[ "$STOP_AFTER" == "2b" ]]; then
        log_success "✅ Stopped after Phase 2b as requested"
        log_info "Infrastructure workspace ready. Credentials preserved in memory."
        return 0
    fi

    log_phase "🚀 Phase 2c: Infrastructure Deployment"
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