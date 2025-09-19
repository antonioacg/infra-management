#!/bin/bash
set -e

# Phase 2: Bootstrap State Backend
# Creates MinIO and PostgreSQL for Terraform state storage

ENVIRONMENT=${1:-homelab}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(dirname "$SCRIPT_DIR")/bootstrap-state"

log_info() { echo -e "\033[0;34mℹ️  $1\033[0m"; }
log_success() { echo -e "\033[0;32m✅ $1\033[0m"; }
log_error() { echo -e "\033[0;31m❌ $1\033[0m"; }

deploy_minimal_minio() {
    log_info "Deploying minimal MinIO for bootstrap..."

    kubectl apply -f "$BOOTSTRAP_DIR/minimal-minio.yaml"

    # Wait for minimal MinIO to be ready
    kubectl wait --for=condition=Ready pod -l app=minimal-minio -n bootstrap-temp --timeout=120s

    # Port-forward for initial access
    kubectl port-forward -n bootstrap-temp svc/minimal-minio 9000:9000 &
    PORT_FORWARD_PID=$!
    sleep 5

    log_success "Minimal MinIO ready"
}

initialize_terraform_state() {
    log_info "Initializing Terraform bootstrap state..."

    cd "$BOOTSTRAP_DIR"

    # Initialize with local backend
    terraform init

    # Apply bootstrap infrastructure
    terraform apply -auto-approve \
        -var="environment=$ENVIRONMENT"

    # Kill port-forward to minimal MinIO
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        kill $PORT_FORWARD_PID 2>/dev/null || true
    fi

    # Wait for proper MinIO to be ready
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=minio -n bootstrap --timeout=180s

    log_success "Bootstrap infrastructure ready"
}

migrate_to_remote_state() {
    log_info "Migrating to remote state backend..."

    # Port-forward to bootstrap MinIO
    kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 &
    PORT_FORWARD_PID=$!
    sleep 10

    # Create bucket if not exists
    mc alias set bootstrap http://localhost:9000 admin minio123 2>/dev/null || {
        log_info "Installing mc client..."
        curl -o /tmp/mc https://dl.min.io/client/mc/release/linux-amd64/mc
        chmod +x /tmp/mc
        /tmp/mc alias set bootstrap http://localhost:9000 admin minio123
    }

    /tmp/mc mb bootstrap/terraform-state 2>/dev/null || log_info "Bucket already exists"

    # Migrate state to remote backend
    terraform init -migrate-state -backend-config=backend-remote.hcl -force-copy

    # Clean up
    kill $PORT_FORWARD_PID 2>/dev/null || true
    kubectl delete -f "$BOOTSTRAP_DIR/minimal-minio.yaml" || true

    log_success "State migrated to remote backend"
}

main() {
    log_info "Starting bootstrap state backend setup..."

    deploy_minimal_minio
    initialize_terraform_state
    migrate_to_remote_state

    log_success "Bootstrap state backend complete"
}

main "$@"