#!/bin/bash
set -e

# Phase 1: System Preparation
# Installs k3s and validates cluster readiness

ENVIRONMENT=${1:-homelab}

log_info() { echo -e "\033[0;34mℹ️  $1\033[0m"; }
log_success() { echo -e "\033[0;32m✅ $1\033[0m"; }
log_error() { echo -e "\033[0;31m❌ $1\033[0m"; }

install_k3s() {
    log_info "Installing k3s..."

    if command -v k3s >/dev/null 2>&1; then
        log_info "k3s already installed"
        return
    fi

    # Install k3s with appropriate configuration for environment
    if [[ "$ENVIRONMENT" == "business" ]]; then
        # Business phase: HA-ready configuration
        curl -sfL https://get.k3s.io | sh -s - server \
            --cluster-init \
            --disable traefik \
            --disable servicelb \
            --write-kubeconfig-mode 644
    else
        # Homelab phase: single node configuration
        curl -sfL https://get.k3s.io | sh -s - \
            --disable traefik \
            --disable servicelb \
            --write-kubeconfig-mode 644
    fi

    # Wait for k3s to be ready
    sleep 10
    until kubectl get nodes >/dev/null 2>&1; do
        log_info "Waiting for k3s to be ready..."
        sleep 5
    done

    log_success "k3s installed and ready"
}

validate_cluster() {
    log_info "Validating cluster..."

    # Check cluster access
    kubectl cluster-info >/dev/null

    # Check storage class
    kubectl get storageclass local-path >/dev/null

    # Wait for system pods
    kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=60s

    log_success "Cluster validation complete"
}

main() {
    log_info "Starting system preparation..."

    install_k3s
    validate_cluster

    log_success "System preparation complete"
}

main "$@"