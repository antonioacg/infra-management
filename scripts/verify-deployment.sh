#!/bin/bash
# Post-Bootstrap Verification Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Global variables for tracking verification results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Function to run a verification check
run_check() {
    local description="$1"
    local command="$2"
    local expected_status="${3:-0}"
    local is_optional="${4:-false}"
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    log_info "Checking: $description"
    
    if eval "$command" >/dev/null 2>&1; then
        local exit_code=$?
        if [ $exit_code -eq $expected_status ]; then
            log_success "$description"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
            return 0
        else
            if [ "$is_optional" = "true" ]; then
                log_warning "$description (optional check failed)"
                WARNING_CHECKS=$((WARNING_CHECKS + 1))
                return 0
            else
                log_error "$description (exit code: $exit_code)"
                FAILED_CHECKS=$((FAILED_CHECKS + 1))
                return 1
            fi
        fi
    else
        if [ "$is_optional" = "true" ]; then
            log_warning "$description (optional check failed)"
            WARNING_CHECKS=$((WARNING_CHECKS + 1))
            return 0
        else
            log_error "$description (command failed)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            return 1
        fi
    fi
}

# Function to check if pods are running
check_pods_running() {
    local namespace="$1"
    local label_selector="$2"
    local description="$3"
    
    run_check "$description" \
        "kubectl get pods -n $namespace -l $label_selector --no-headers | awk '{print \$3}' | grep -v Running | wc -l | grep -q '^0$'"
}

# Function to check service endpoints
check_service_endpoints() {
    local namespace="$1" 
    local service="$2"
    local description="$3"
    
    run_check "$description" \
        "kubectl get endpoints -n $namespace $service -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -q ."
}

# Function to check HTTP endpoint
check_http_endpoint() {
    local url="$1"
    local description="$2" 
    local expected_code="${3:-200}"
    local is_optional="${4:-false}"
    
    run_check "$description" \
        "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 '$url' | grep -q '^$expected_code$'" \
        0 "$is_optional"
}

# Check Kubernetes cluster health
check_kubernetes() {
    echo ""
    log_info "=== Kubernetes Cluster Health ==="
    
    run_check "Kubernetes API server" \
        "kubectl cluster-info --request-timeout=10s"
    
    run_check "All nodes ready" \
        "kubectl get nodes --no-headers | awk '{print \$2}' | grep -v Ready | wc -l | grep -q '^0$'"
    
    run_check "System pods running" \
        "kubectl get pods -n kube-system --no-headers | awk '{print \$3}' | grep -v Running | grep -v Completed | wc -l | grep -q '^0$'"
}

# Check Flux GitOps
check_flux() {
    echo ""
    log_info "=== Flux GitOps Status ==="
    
    run_check "Flux system pods" \
        "kubectl get pods -n flux-system --no-headers | awk '{print \$3}' | grep -v Running | wc -l | grep -q '^0$'"
    
    run_check "Git repository source" \
        "flux get sources git deployments --namespace flux-system | grep -q 'True.*Fetched'"
    
    run_check "Kustomization ready" \
        "flux get kustomizations production --namespace flux-system | grep -q 'True.*Applied'"
    
    run_check "SOPS decryption working" \
        "kubectl get secret -n flux-system sops-age" \
        0 true
}

# Check Vault
check_vault() {
    echo ""
    log_info "=== HashiCorp Vault Status ==="
    
    check_pods_running "vault" "app.kubernetes.io/name=vault" "Vault pods running"
    
    check_service_endpoints "vault" "vault" "Vault service endpoints"
    
    run_check "Vault unsealed and ready" \
        "kubectl exec -n vault vault-0 -- vault status | grep -q 'Sealed.*false'"
    
    run_check "Kubernetes auth enabled" \
        "kubectl exec -n vault vault-0 -- vault auth list | grep -q kubernetes"
    
    run_check "KV secrets engine enabled" \
        "kubectl exec -n vault vault-0 -- vault secrets list | grep -q 'secret/'" \
        0 true
}

# Check MinIO
check_minio() {
    echo ""
    log_info "=== MinIO Object Storage ==="
    
    check_pods_running "minio" "app=minio" "MinIO pods running"
    
    check_service_endpoints "minio" "minio" "MinIO service endpoints"
    
    check_http_endpoint "http://minio.minio.svc.cluster.local:9000/minio/health/live" \
        "MinIO health endpoint" 200 true
}

# Check External Secrets Operator
check_external_secrets() {
    echo ""
    log_info "=== External Secrets Operator ==="
    
    run_check "External Secrets Operator installed" \
        "kubectl get namespace external-secrets-system" \
        0 true
    
    if kubectl get namespace external-secrets-system >/dev/null 2>&1; then
        check_pods_running "external-secrets-system" "app.kubernetes.io/name=external-secrets" \
            "External Secrets Operator pods"
        
        run_check "ClusterSecretStore configured" \
            "kubectl get clustersecretstore vault-backend" \
            0 true
        
        run_check "External secrets syncing" \
            "kubectl get externalsecrets -A --no-headers | awk '{print \$4}' | grep -v SecretSynced | wc -l | grep -q '^0$'" \
            0 true
    else
        log_warning "External Secrets Operator not deployed (expected for initial bootstrap)"
        WARNING_CHECKS=$((WARNING_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    fi
}

# Check Cloudflared
check_cloudflared() {
    echo ""
    log_info "=== Cloudflared Tunnel ==="
    
    run_check "Cloudflared namespace exists" \
        "kubectl get namespace cloudflared" \
        0 true
    
    if kubectl get namespace cloudflared >/dev/null 2>&1; then
        check_pods_running "cloudflared" "app=cloudflared" "Cloudflared pods running"
        
        run_check "Cloudflared credentials secret" \
            "kubectl get secret -n cloudflared cloudflared-credentials" \
            0 true
        
        run_check "Cloudflared config" \
            "kubectl get configmap -n cloudflared cloudflared-config" \
            0 true
    else
        log_warning "Cloudflared not deployed (may not be in initial deployment)"
        WARNING_CHECKS=$((WARNING_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    fi
}

# Check Nginx Ingress
check_nginx_ingress() {
    echo ""
    log_info "=== Nginx Ingress Controller ==="
    
    run_check "Ingress nginx namespace" \
        "kubectl get namespace ingress-nginx" \
        0 true
    
    if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
        check_pods_running "ingress-nginx" "app.kubernetes.io/component=controller" \
            "Nginx ingress controller pods"
        
        check_service_endpoints "ingress-nginx" "ingress-nginx-controller" \
            "Nginx ingress service endpoints"
    else
        log_warning "Nginx Ingress Controller not deployed"
        WARNING_CHECKS=$((WARNING_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    fi
}

# Check network connectivity
check_network() {
    echo ""
    log_info "=== Network Connectivity ==="
    
    run_check "DNS resolution working" \
        "kubectl exec -n default -c busybox --stdin --tty busybox-test -- nslookup kubernetes.default.svc.cluster.local" \
        0 true || run_check "Create busybox for testing" \
        "kubectl run busybox-test --image=busybox --restart=Never -- sleep 3600" \
        0 true
    
    run_check "Internal service communication" \
        "kubectl exec -n default -c busybox busybox-test -- wget -qO- --timeout=5 http://vault.vault.svc.cluster.local:8200/v1/sys/health" \
        0 true
}

# Check persistent volumes
check_storage() {
    echo ""
    log_info "=== Persistent Storage ==="
    
    run_check "Persistent volumes available" \
        "kubectl get pv | grep -q Available" \
        0 true
    
    run_check "Persistent volume claims bound" \
        "kubectl get pvc -A --no-headers | awk '{print \$3}' | grep -v Bound | wc -l | grep -q '^0$'" \
        0 true
    
    run_check "Storage class available" \
        "kubectl get storageclass | grep -q local-path" \
        0 true
}

# Resource usage check
check_resources() {
    echo ""
    log_info "=== Resource Usage ==="
    
    run_check "Node resources available" \
        "kubectl describe nodes | grep -A5 'Allocated resources' | grep -E '(cpu|memory)' | grep -v '0 ' | wc -l | grep -q ."
    
    run_check "No pods in pending state" \
        "kubectl get pods -A --field-selector=status.phase=Pending --no-headers | wc -l | grep -q '^0$'"
    
    run_check "No pods failing" \
        "kubectl get pods -A --field-selector=status.phase=Failed --no-headers | wc -l | grep -q '^0$'"
}

# Security checks
check_security() {
    echo ""
    log_info "=== Security Configuration ==="
    
    run_check "RBAC enabled" \
        "kubectl auth can-i create pods --as=system:unauthenticated" \
        1  # Should fail for unauthenticated user
    
    run_check "Network policies exist" \
        "kubectl get networkpolicies -A" \
        0 true
    
    run_check "Pod security policies" \
        "kubectl get podsecuritypolicy" \
        0 true
}

# Performance and health summary
generate_summary() {
    echo ""
    log_info "=== Deployment Summary ==="
    
    echo "Total Checks: $TOTAL_CHECKS"
    echo "✅ Passed: $PASSED_CHECKS"
    echo "❌ Failed: $FAILED_CHECKS" 
    echo "⚠️  Warnings: $WARNING_CHECKS"
    echo ""
    
    if [ $FAILED_CHECKS -eq 0 ]; then
        if [ $WARNING_CHECKS -eq 0 ]; then
            log_success "🎉 All verification checks passed! Deployment is healthy."
            echo ""
            echo "Your zero-secrets Kubernetes infrastructure is fully operational:"
            echo "  • GitOps pipeline: kubectl get pods -n flux-system"  
            echo "  • Secret management: kubectl exec -n vault vault-0 -- vault status"
            echo "  • Secret synchronization: kubectl get externalsecrets -A"
            echo "  • Application access: Check your Cloudflare tunnel"
            return 0
        else
            log_warning "✅ Core checks passed with $WARNING_CHECKS warnings. Deployment is functional."
            echo ""
            echo "Review warnings above - they may indicate optional components not yet deployed."
            return 0
        fi
    else
        log_error "❌ $FAILED_CHECKS critical checks failed. Deployment needs attention."
        echo ""
        echo "Common troubleshooting steps:"
        echo "  • Check pod status: kubectl get pods -A"
        echo "  • View logs: kubectl logs -n <namespace> <pod-name>"
        echo "  • Verify Flux: flux get all --all-namespaces"
        echo "  • Check Vault: kubectl exec -n vault vault-0 -- vault status"
        return 1
    fi
}

# Cleanup test resources
cleanup() {
    log_info "Cleaning up test resources"
    kubectl delete pod busybox-test 2>/dev/null || true
}

# Main verification function
main() {
    echo "🔍 Post-Bootstrap Deployment Verification"
    echo "========================================"
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Run all verification checks
    check_kubernetes
    check_flux
    check_vault
    check_minio
    check_external_secrets
    check_cloudflared  
    check_nginx_ingress
    check_network
    check_storage
    check_resources
    check_security
    
    # Generate summary
    generate_summary
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi