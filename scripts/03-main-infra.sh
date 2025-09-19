#!/bin/bash
set -e

# Phase 3: Main Infrastructure
# Deploys Vault, External Secrets, and Networking via Terraform

ENVIRONMENT=${1:-homelab}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/infra/environments/production"

log_info() { echo -e "\033[0;34mℹ️  $1\033[0m"; }
log_success() { echo -e "\033[0;32m✅ $1\033[0m"; }
log_error() { echo -e "\033[0;31m❌ $1\033[0m"; }

setup_port_forwards() {
    log_info "Setting up port forwards for Terraform providers..."

    # Port-forward to bootstrap MinIO for Terraform backend
    kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 &
    MINIO_PF_PID=$!

    # Port-forward to Vault (if already exists) for Terraform provider
    if kubectl get svc vault -n vault >/dev/null 2>&1; then
        kubectl port-forward -n vault svc/vault 8200:8200 &
        VAULT_PF_PID=$!
    fi

    sleep 10
    log_success "Port forwards ready"
}

deploy_infrastructure() {
    log_info "Deploying main infrastructure with Terraform..."

    cd "$INFRA_DIR"

    # Set environment variables for Terraform
    export TF_VAR_environment="$ENVIRONMENT"
    export TF_VAR_github_token="$GITHUB_TOKEN"
    export TF_VAR_cloudflare_tunnel_token="${CLOUDFLARE_TUNNEL_TOKEN:-}"

    # Initialize Terraform with remote backend
    terraform init

    # Plan and apply infrastructure
    terraform plan -var-file=terraform.tfvars
    terraform apply -auto-approve -var-file=terraform.tfvars

    log_success "Infrastructure deployment complete"
}

wait_for_services() {
    log_info "Waiting for infrastructure services to be ready..."

    # Wait for Vault
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s

    # Wait for External Secrets
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=external-secrets -n external-secrets-system --timeout=180s

    # Wait for Nginx Ingress
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=180s

    log_success "All infrastructure services ready"
}

cleanup_port_forwards() {
    log_info "Cleaning up port forwards..."

    [[ -n "$MINIO_PF_PID" ]] && kill $MINIO_PF_PID 2>/dev/null || true
    [[ -n "$VAULT_PF_PID" ]] && kill $VAULT_PF_PID 2>/dev/null || true

    log_success "Port forwards cleaned up"
}

main() {
    log_info "Starting main infrastructure deployment..."

    setup_port_forwards

    trap cleanup_port_forwards EXIT

    deploy_infrastructure
    wait_for_services

    log_success "Main infrastructure deployment complete"
}

main "$@"