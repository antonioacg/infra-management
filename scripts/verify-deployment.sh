#!/bin/bash
set -e

# Zero-Secrets Phase-Based Deployment Verification Script
# Comprehensive verification of all phases of the bootstrap process

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_phase() {
    echo -e "${PURPLE}🔍 VERIFICATION PHASE $1: $2${NC}"
    echo "=================================================="
}

verify_phase1_infrastructure() {
    log_phase "1" "Core Infrastructure Components"
    
    local errors=0
    
    # Verify k3s cluster
    log_info "Checking Kubernetes cluster..."
    if kubectl cluster-info >/dev/null 2>&1; then
        log_success "Kubernetes cluster is running"
        kubectl get nodes --no-headers | while read node status _; do
            if [[ "$status" == "Ready" ]]; then
                log_success "Node $node is Ready"
            else
                log_error "Node $node is not Ready (status: $status)"
                ((errors++))
            fi
        done
    else
        log_error "Kubernetes cluster is not accessible"
        ((errors++))
    fi
    
    # Verify Flux installation
    log_info "Checking Flux installation..."
    if flux check >/dev/null 2>&1; then
        log_success "Flux is installed and healthy"
    else
        log_error "Flux installation has issues"
        ((errors++))
    fi
    
    # Verify Flux components
    log_info "Checking Flux components..."
    local flux_components=("source-controller" "kustomize-controller" "helm-controller" "notification-controller")
    for component in "${flux_components[@]}"; do
        if kubectl get deployment "$component" -n flux-system >/dev/null 2>&1; then
            local ready=$(kubectl get deployment "$component" -n flux-system -o jsonpath='{.status.readyReplicas}')
            local desired=$(kubectl get deployment "$component" -n flux-system -o jsonpath='{.spec.replicas}')
            if [[ "$ready" == "$desired" && "$ready" -gt 0 ]]; then
                log_success "Flux $component is ready ($ready/$desired)"
            else
                log_error "Flux $component is not ready ($ready/$desired)"
                ((errors++))
            fi
        else
            log_error "Flux $component not found"
            ((errors++))
        fi
    done
    
    # Verify Vault
    log_info "Checking Vault deployment..."
    if kubectl get pods -n vault -l app.kubernetes.io/name=vault --no-headers 2>/dev/null | grep -q "Running"; then
        log_success "Vault pod is running"
        
        # Check Vault status
        if kubectl exec -n vault vault-0 -- vault status >/dev/null 2>&1; then
            log_success "Vault is unsealed and ready"
        else
            log_error "Vault is not properly unsealed"
            ((errors++))
        fi
    else
        log_error "Vault pod is not running"
        ((errors++))
    fi
    
    # Verify External Secrets Operator
    log_info "Checking External Secrets Operator..."
    if kubectl get deployment external-secrets -n external-secrets-system >/dev/null 2>&1; then
        local ready=$(kubectl get deployment external-secrets -n external-secrets-system -o jsonpath='{.status.readyReplicas}')
        local desired=$(kubectl get deployment external-secrets -n external-secrets-system -o jsonpath='{.spec.replicas}')
        if [[ "$ready" == "$desired" && "$ready" -gt 0 ]]; then
            log_success "External Secrets Operator is ready ($ready/$desired)"
        else
            log_error "External Secrets Operator is not ready ($ready/$desired)"
            ((errors++))
        fi
    else
        log_error "External Secrets Operator not found"
        ((errors++))
    fi
    
    return $errors
}

verify_phase2_secrets() {
    log_phase "2" "Secret Population in Vault"
    
    local errors=0
    
    # Verify Vault connectivity
    log_info "Checking Vault secret storage..."
    kubectl port-forward -n vault svc/vault 8200:8200 >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 3
    
    export VAULT_ADDR="http://localhost:8200"
    if kubectl get secret -n vault vault-init-keys >/dev/null 2>&1; then
        export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
    else
        log_error "Cannot retrieve Vault token"
        kill $pf_pid 2>/dev/null || true
        return 1
    fi
    
    # Check if secrets exist in Vault
    local expected_secrets=("github/auth" "cloudflare/tunnel")
    for secret_path in "${expected_secrets[@]}"; do
        if vault kv get "secret/$secret_path" >/dev/null 2>&1; then
            log_success "Secret $secret_path exists in Vault"
        else
            log_error "Secret $secret_path not found in Vault"
            ((errors++))
        fi
    done
    
    # Cleanup port-forward
    kill $pf_pid 2>/dev/null || true
    unset VAULT_ADDR VAULT_TOKEN
    
    return $errors
}

verify_phase3_flux_auth() {
    log_phase "3" "Flux External Secrets Authentication"
    
    local errors=0
    
    # Verify Flux Git auth External Secret exists
    log_info "Checking Flux Git authentication External Secret..."
    if kubectl get externalsecret flux-git-auth -n flux-system >/dev/null 2>&1; then
        local status=$(kubectl get externalsecret flux-git-auth -n flux-system -o jsonpath='{.status.conditions[0].status}')
        if [[ "$status" == "True" ]]; then
            log_success "Flux Git auth External Secret is synced"
        else
            log_error "Flux Git auth External Secret sync failed"
            ((errors++))
        fi
    else
        log_error "Flux Git auth External Secret not found"
        ((errors++))
    fi
    
    # Verify the secret was created
    log_info "Checking Flux Git authentication secret..."
    if kubectl get secret flux-git-auth -n flux-system >/dev/null 2>&1; then
        log_success "Flux Git auth secret exists"
    else
        log_error "Flux Git auth secret not found"
        ((errors++))
    fi
    
    # Verify Flux is using the External Secret
    log_info "Checking Flux GitRepository configuration..."
    if kubectl get gitrepository flux-system -n flux-system -o jsonpath='{.spec.secretRef.name}' | grep -q "flux-git-auth"; then
        log_success "Flux is configured to use External Secret for Git authentication"
    else
        log_warning "Flux may not be using External Secret for Git authentication"
    fi
    
    return $errors
}

verify_phase4_applications() {
    log_phase "4" "Application Deployment and External Secrets"
    
    local errors=0
    
    # Verify ClusterSecretStore
    log_info "Checking ClusterSecretStore..."
    if kubectl get clustersecretstore vault-backend >/dev/null 2>&1; then
        local status=$(kubectl get clustersecretstore vault-backend -o jsonpath='{.status.conditions[0].status}')
        if [[ "$status" == "True" ]]; then
            log_success "ClusterSecretStore vault-backend is ready"
        else
            log_error "ClusterSecretStore vault-backend is not ready"
            ((errors++))
        fi
    else
        log_error "ClusterSecretStore vault-backend not found"
        ((errors++))
    fi
    
    # Verify External Secrets
    log_info "Checking External Secrets sync status..."
    local external_secrets_count=$(kubectl get externalsecrets -A --no-headers 2>/dev/null | wc -l)
    if [[ $external_secrets_count -gt 0 ]]; then
        log_success "Found $external_secrets_count External Secret(s)"
        
        # Check sync status
        local synced_count=$(kubectl get externalsecrets -A --no-headers 2>/dev/null | grep -c "True" || echo "0")
        if [[ $synced_count -eq $external_secrets_count ]]; then
            log_success "All External Secrets are synced ($synced_count/$external_secrets_count)"
        else
            log_warning "Some External Secrets are not synced ($synced_count/$external_secrets_count)"
        fi
    else
        log_warning "No External Secrets found"
    fi
    
    # Verify application pods
    log_info "Checking application pods..."
    local app_namespaces=("cloudflared" "ingress-nginx")
    for namespace in "${app_namespaces[@]}"; do
        if kubectl get namespace "$namespace" >/dev/null 2>&1; then
            local pod_count=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l)
            local running_count=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
            if [[ $pod_count -gt 0 ]]; then
                if [[ $running_count -eq $pod_count ]]; then
                    log_success "All pods in $namespace are running ($running_count/$pod_count)"
                else
                    log_warning "Some pods in $namespace are not running ($running_count/$pod_count)"
                fi
            else
                log_info "No pods found in $namespace namespace"
            fi
        fi
    done
    
    return $errors
}

verify_phase5_security() {
    log_phase "5" "Security and Environment Cleanup"
    
    local errors=0
    
    # Check for secrets in environment
    log_info "Checking environment for leaked secrets..."
    local secret_patterns=("token" "secret" "password" "key")
    local env_secrets=0
    
    for pattern in "${secret_patterns[@]}"; do
        # Exclude known safe environment variables
        if env | grep -v "^HOME\|^PATH\|^USER\|^KUBECONFIG\|^WORKSPACE\|^PWD\|^OLDPWD\|^SHELL\|^TERM" | grep -qi "$pattern"; then
            ((env_secrets++))
        fi
    done
    
    if [[ $env_secrets -eq 0 ]]; then
        log_success "No secrets found in environment variables"
    else
        log_warning "Potential secrets found in environment (review manually)"
    fi
    
    # Verify Vault unseal keys are properly stored
    log_info "Checking Vault unseal key security..."
    if kubectl get secret vault-init-keys -n vault >/dev/null 2>&1; then
        log_success "Vault unseal keys properly stored in Kubernetes secret"
    else
        log_error "Vault unseal keys secret not found"
        ((errors++))
    fi
    
    # Check RBAC for External Secrets
    log_info "Checking External Secrets RBAC..."
    if kubectl get clusterrole external-secrets-operator >/dev/null 2>&1; then
        log_success "External Secrets ClusterRole exists"
    else
        log_error "External Secrets ClusterRole not found"
        ((errors++))
    fi
    
    return $errors
}

verify_overall_health() {
    log_phase "OVERALL" "System Health Summary"
    
    echo ""
    echo "🔍 Comprehensive System Status:"
    echo "================================"
    
    # Kubernetes cluster
    echo ""
    echo "📊 Cluster Nodes:"
    kubectl get nodes
    
    # Flux status
    echo ""
    echo "📊 Flux Status:"
    flux get all --all-namespaces
    
    # Vault status
    echo ""
    echo "📊 Vault Status:"
    kubectl exec -n vault vault-0 -- vault status 2>/dev/null || log_warning "Cannot check Vault status"
    
    # External Secrets
    echo ""
    echo "📊 External Secrets:"
    kubectl get externalsecrets -A
    
    # All pods status
    echo ""
    echo "📊 All Pods Status:"
    kubectl get pods -A | grep -E "(vault|cloudflared|external-secrets|flux|nginx)" || log_info "No specific application pods found"
    
    # Secrets created by External Secrets
    echo ""
    echo "📊 Secrets Created by External Secrets:"
    kubectl get secrets -A | grep -v "kubernetes.io" | grep -v "helm.sh" | grep -v "Opaque.*0" || log_info "No External Secrets synced yet"
    
    echo ""
}

main() {
    echo "🔍 Zero-Secrets Phase-Based Deployment Verification"
    echo "=================================================="
    echo ""
    
    local total_errors=0
    
    # Run all verification phases
    verify_phase1_infrastructure
    ((total_errors += $?))
    
    echo ""
    verify_phase2_secrets
    ((total_errors += $?))
    
    echo ""
    verify_phase3_flux_auth
    ((total_errors += $?))
    
    echo ""
    verify_phase4_applications
    ((total_errors += $?))
    
    echo ""
    verify_phase5_security
    ((total_errors += $?))
    
    echo ""
    verify_overall_health
    
    # Final result
    echo ""
    echo "==============================================="
    if [[ $total_errors -eq 0 ]]; then
        log_success "🎉 All verification phases passed! Zero-secrets infrastructure is healthy."
    else
        log_warning "⚠️  Verification completed with $total_errors issue(s). Review the output above."
    fi
    echo "==============================================="
    
    return $total_errors
}

# Execute main function
main "$@"