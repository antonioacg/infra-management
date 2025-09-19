#!/bin/bash
set -e

# Phase 5: GitOps Activation
# Activates Flux for application deployment

ENVIRONMENT=${1:-homelab}

log_info() { echo -e "\033[0;34mℹ️  $1\033[0m"; }
log_success() { echo -e "\033[0;32m✅ $1\033[0m"; }
log_error() { echo -e "\033[0;31m❌ $1\033[0m"; }

install_flux() {
    log_info "Installing Flux controllers..."

    if ! command -v flux >/dev/null 2>&1; then
        log_info "Installing Flux CLI..."
        curl -s https://fluxcd.io/install.sh | sudo bash
    fi

    # Install Flux controllers
    flux install

    # Wait for controllers to be ready
    kubectl wait --for=condition=Ready pod -l app=source-controller -n flux-system --timeout=120s
    kubectl wait --for=condition=Ready pod -l app=kustomize-controller -n flux-system --timeout=120s
    kubectl wait --for=condition=Ready pod -l app=helm-controller -n flux-system --timeout=120s

    log_success "Flux controllers ready"
}

setup_git_source() {
    log_info "Setting up Git repository source..."

    # Create GitHub authentication secret
    kubectl create secret generic github-auth \
        --from-literal=password="$GITHUB_TOKEN" \
        -n flux-system \
        --dry-run=client -o yaml | kubectl apply -f -

    # Create Git repository source
    flux create source git deployments \
        --url=https://github.com/antonioacg/deployments \
        --branch=main \
        --secret-ref=github-auth \
        --interval=1m

    log_success "Git repository source configured"
}

activate_applications() {
    log_info "Activating application deployments..."

    # Create kustomization for the production cluster
    flux create kustomization production \
        --source=deployments \
        --path="./clusters/production" \
        --prune=true \
        --interval=5m \
        --retry-interval=2m

    log_success "Application deployments activated"
}

wait_for_sync() {
    log_info "Waiting for initial sync..."

    # Wait for Git repository to sync
    flux get sources git --timeout=2m

    # Wait for kustomization to sync
    flux get kustomizations --timeout=5m

    log_success "GitOps sync complete"
}

verify_deployment() {
    log_info "Verifying application deployment..."

    # Check that applications are being deployed
    kubectl get kustomizations -n flux-system

    # Check application namespaces
    sleep 30
    kubectl get pods -A | grep -v kube-system | grep -v flux-system | grep -v bootstrap || true

    log_success "Application deployment verification complete"
}

main() {
    log_info "Starting GitOps activation..."

    install_flux
    setup_git_source
    activate_applications
    wait_for_sync
    verify_deployment

    log_success "GitOps activation complete"
}

main "$@"