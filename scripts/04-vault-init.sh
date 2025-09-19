#!/bin/bash
set -e

# Phase 4: Vault Initialization
# Initializes Vault and configures authentication backends

ENVIRONMENT=${1:-homelab}

log_info() { echo -e "\033[0;34mℹ️  $1\033[0m"; }
log_success() { echo -e "\033[0;32m✅ $1\033[0m"; }
log_error() { echo -e "\033[0;31m❌ $1\033[0m"; }

setup_vault_access() {
    log_info "Setting up Vault access..."

    # Port-forward to Vault
    kubectl port-forward -n vault svc/vault 8200:8200 &
    VAULT_PF_PID=$!
    sleep 10

    export VAULT_ADDR="http://localhost:8200"
    export VAULT_SKIP_VERIFY=true

    log_success "Vault access configured"
}

initialize_vault() {
    log_info "Initializing Vault..."

    # Check if Vault is already initialized
    if vault status >/dev/null 2>&1; then
        log_info "Vault already initialized and unsealed"
        return
    fi

    # Check if initialization data exists
    if kubectl get secret vault-init -n vault >/dev/null 2>&1; then
        log_info "Vault initialization data found, unsealing..."
        unseal_vault
        return
    fi

    # Initialize Vault
    vault operator init \
        -key-shares=5 \
        -key-threshold=3 \
        -format=json > /tmp/vault-init.json

    # Extract keys and token
    UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' /tmp/vault-init.json)
    UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' /tmp/vault-init.json)
    UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' /tmp/vault-init.json)
    ROOT_TOKEN=$(jq -r '.root_token' /tmp/vault-init.json)

    # Store in Kubernetes secret
    kubectl create secret generic vault-init \
        --from-literal=unseal-key-1="$UNSEAL_KEY_1" \
        --from-literal=unseal-key-2="$UNSEAL_KEY_2" \
        --from-literal=unseal-key-3="$UNSEAL_KEY_3" \
        --from-literal=root-token="$ROOT_TOKEN" \
        -n vault

    # Unseal Vault
    vault operator unseal "$UNSEAL_KEY_1"
    vault operator unseal "$UNSEAL_KEY_2"
    vault operator unseal "$UNSEAL_KEY_3"

    export VAULT_TOKEN="$ROOT_TOKEN"

    log_success "Vault initialized and unsealed"
}

unseal_vault() {
    log_info "Unsealing Vault with stored keys..."

    UNSEAL_KEY_1=$(kubectl get secret vault-init -n vault -o jsonpath='{.data.unseal-key-1}' | base64 -d)
    UNSEAL_KEY_2=$(kubectl get secret vault-init -n vault -o jsonpath='{.data.unseal-key-2}' | base64 -d)
    UNSEAL_KEY_3=$(kubectl get secret vault-init -n vault -o jsonpath='{.data.unseal-key-3}' | base64 -d)

    vault operator unseal "$UNSEAL_KEY_1"
    vault operator unseal "$UNSEAL_KEY_2"
    vault operator unseal "$UNSEAL_KEY_3"

    ROOT_TOKEN=$(kubectl get secret vault-init -n vault -o jsonpath='{.data.root-token}' | base64 -d)
    export VAULT_TOKEN="$ROOT_TOKEN"

    log_success "Vault unsealed"
}

configure_auth_backends() {
    log_info "Configuring Vault authentication backends..."

    # Enable Kubernetes auth
    vault auth enable kubernetes || log_info "Kubernetes auth already enabled"

    # Configure Kubernetes auth
    vault write auth/kubernetes/config \
        token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        kubernetes_host="https://kubernetes.default.svc:443" \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt || {
        # Fallback for external access
        vault write auth/kubernetes/config \
            kubernetes_host="https://kubernetes.default.svc:443"
    }

    log_success "Authentication backends configured"
}

configure_secrets_engines() {
    log_info "Configuring secrets engines..."

    # Enable KV v2 secrets engine
    vault secrets enable -path=secret kv-v2 || log_info "KV secrets engine already enabled"

    # Store essential secrets
    vault kv put secret/github token="$GITHUB_TOKEN"

    if [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
        vault kv put secret/cloudflare tunnel-token="$CLOUDFLARE_TUNNEL_TOKEN"
    fi

    log_success "Secrets engines configured"
}

configure_policies_and_roles() {
    log_info "Configuring policies and roles..."

    # External Secrets policy
    vault policy write external-secrets - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
EOF

    # External Secrets role
    vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets-vault \
        bound_service_account_namespaces=external-secrets-system \
        policies=external-secrets \
        ttl=24h

    # Terraform policy
    vault policy write terraform - <<EOF
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "auth/kubernetes/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

    # Terraform role
    vault write auth/kubernetes/role/terraform \
        bound_service_account_names=terraform \
        bound_service_account_namespaces=vault \
        policies=terraform \
        ttl=24h

    log_success "Policies and roles configured"
}

cleanup() {
    log_info "Cleaning up..."
    [[ -n "$VAULT_PF_PID" ]] && kill $VAULT_PF_PID 2>/dev/null || true
    rm -f /tmp/vault-init.json
}

main() {
    log_info "Starting Vault initialization..."

    trap cleanup EXIT

    setup_vault_access
    initialize_vault
    configure_auth_backends
    configure_secrets_engines
    configure_policies_and_roles

    log_success "Vault initialization complete"
}

main "$@"