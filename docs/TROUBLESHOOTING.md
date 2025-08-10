# Troubleshooting Guide

## Common Bootstrap Issues

### 1. Bootstrap Script Fails to Download

**Symptoms:**
- `curl: command not found`
- Connection timeouts or SSL errors

**Solutions:**
```bash
# Install curl if missing
sudo apt update && sudo apt install -y curl

# Use alternative download methods
wget -qO- https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \
  bash -s "token" "key" "tunnel_token"

# Check internet connectivity
ping -c 3 8.8.8.8
```

### 2. k3s Installation Failures

**Symptoms:**
- Permission denied errors
- Port conflicts (6443, 10250)
- Systemd service failures

**Solutions:**
```bash
# Check for existing Kubernetes installations
ps aux | grep -E "(kubelet|kube-)"
sudo systemctl status k3s

# Clean up previous installations
sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
sudo systemctl stop k3s 2>/dev/null || true

# Check port availability
sudo netstat -tlnp | grep -E "(6443|10250)"

# Manual k3s installation with logging
curl -sfL https://get.k3s.io | INSTALL_K3S_LOG=/tmp/k3s-install.log sh -
```

### 3. GitHub Authentication Issues

**Symptoms:**
- `fatal: repository 'https://github.com/...' not found`
- `remote: Repository not found`

**Solutions:**
```bash
# Verify GitHub token permissions
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user

# Test repository access
git clone https://github.com/antonioacg/deployments.git /tmp/test-clone

# Check token scopes (needs repo access)
curl -H "Authorization: token $GITHUB_TOKEN" -I https://api.github.com/user \
  | grep -i x-oauth-scopes
```

### 4. SOPS/Age Configuration Problems

**Symptoms:**
- `error: failed to decrypt`
- `no age identity found`
- SOPS decryption failures

**Solutions:**
```bash
# Verify Age key format
grep "^AGE-SECRET-KEY-" ~/.config/sops/age/keys.txt

# Test SOPS encryption/decryption
echo "test: secret" | sops --encrypt --age $(grep "^# public key:" ~/.config/sops/age/keys.txt | cut -d' ' -f4) /dev/stdin

# Check file permissions
ls -la ~/.config/sops/age/keys.txt  # Should be 600

# Extract public key
grep '^# public key:' ~/.config/sops/age/keys.txt | cut -d' ' -f4
```

### 5. Vault Initialization Issues

**Symptoms:**
- Vault pods in CrashLoopBackOff
- `connection refused` errors
- Initialization timeouts

**Solutions:**
```bash
# Check Vault pod status
kubectl get pods -n vault -l app.kubernetes.io/name=vault

# View Vault logs
kubectl logs -n vault -l app.kubernetes.io/name=vault --tail=50

# Check Vault service
kubectl get svc -n vault

# Manual Vault status check
kubectl exec -n vault vault-0 -- vault status

# Verify MinIO backend connectivity
kubectl get pods -n minio
kubectl logs -n minio -l app=minio
```

### 6. External Secrets Operator Problems

**Symptoms:**
- External secrets not syncing
- `SecretStore` connection errors
- Missing Kubernetes secrets

**Solutions:**
```bash
# Check External Secrets Operator status
kubectl get pods -n external-secrets-system

# Verify ClusterSecretStore
kubectl get clustersecretstore vault-backend -o yaml

# Check ExternalSecret status
kubectl get externalsecrets -A
kubectl describe externalsecret <name> -n <namespace>

# Verify Vault Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth list

# Test service account permissions
kubectl auth can-i get secrets --as=system:serviceaccount:external-secrets-system:external-secrets-operator
```

### 7. Terraform Execution Failures

**Symptoms:**
- `terraform init` failures
- Provider authentication errors
- State backend issues

**Solutions:**
```bash
# Check Terraform version
terraform version

# Verify Vault connectivity
export VAULT_ADDR="http://localhost:8200"
vault status

# Test port-forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &
curl -s http://localhost:8200/v1/sys/health

# Check Terraform state backend
terraform state list

# Verify environment variables
env | grep -E "(TF_VAR_|VAULT_)"
```

### 8. Flux GitOps Issues

**Symptoms:**
- Flux reconciliation failures
- Git repository sync errors
- Kustomization failures

**Solutions:**
```bash
# Check Flux status
flux get all --all-namespaces

# Verify Git source
flux get sources git -A

# Check Kustomization status
flux get kustomizations -A

# View Flux logs
kubectl logs -n flux-system -l app=source-controller
kubectl logs -n flux-system -l app=kustomize-controller

# Force reconciliation
flux reconcile source git deployments
flux reconcile kustomization production
```

## Network Connectivity Issues

### 9. Cloudflared Tunnel Problems

**Symptoms:**
- Services not accessible externally
- Tunnel authentication failures
- DNS resolution issues

**Solutions:**
```bash
# Check cloudflared pod status
kubectl get pods -n cloudflared -l app=cloudflared

# View cloudflared logs
kubectl logs -n cloudflared -l app=cloudflared --tail=50

# Verify tunnel credentials
kubectl get secret -n cloudflared cloudflared-credentials

# Check ingress configuration
kubectl get configmap -n cloudflared cloudflared-config -o yaml

# Test internal service connectivity
kubectl exec -n cloudflared -it <pod> -- wget -qO- http://nginx-ingress-controller.ingress-nginx.svc.cluster.local
```

### 10. Nginx Ingress Controller Issues

**Symptoms:**
- 502/503 errors from external access
- Backend service connectivity problems
- SSL/TLS certificate issues

**Solutions:**
```bash
# Check ingress controller status
kubectl get pods -n ingress-nginx

# View ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller

# Check ingress resources
kubectl get ingress -A

# Verify service endpoints
kubectl get endpoints -A

# Test service connectivity
kubectl exec -n ingress-nginx -it <ingress-pod> -- curl -v http://<service>.<namespace>.svc.cluster.local
```

## Resource and Performance Issues

### 11. Pod Resource Constraints

**Symptoms:**
- Pods stuck in Pending state
- Out of memory kills
- CPU throttling

**Solutions:**
```bash
# Check node resources
kubectl top nodes
kubectl describe nodes

# Check pod resource usage
kubectl top pods -A

# View resource requests/limits
kubectl describe pod <pod-name> -n <namespace>

# Check for resource quotas
kubectl get resourcequotas -A

# Increase node resources or adjust pod limits
```

### 12. Storage Issues

**Symptoms:**
- PVC stuck in Pending
- Disk space errors
- Backup failures

**Solutions:**
```bash
# Check storage classes
kubectl get storageclass

# View PVC status
kubectl get pvc -A

# Check node disk usage
df -h

# MinIO storage issues
kubectl exec -n minio -it <minio-pod> -- df -h /data

# Clean up unused resources
kubectl delete pod --field-selector=status.phase=Succeeded -A
docker system prune -f
```

## Recovery Procedures

### 13. Complete System Recovery

**When to use:** Catastrophic failures, corrupted state

**Steps:**
```bash
# 1. Backup any critical data
kubectl get secret -o yaml -A > secrets-backup.yaml

# 2. Clean installation
sudo /usr/local/bin/k3s-uninstall.sh
sudo rm -rf /var/lib/rancher/k3s/*

# 3. Re-run bootstrap
curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \
  bash -s "$GITHUB_TOKEN" "$SOPS_AGE_KEY" "$CLOUDFLARE_TUNNEL_TOKEN"
```

### 14. Partial Component Recovery

**Vault Recovery:**
```bash
# Re-initialize Vault
kubectl delete job -n vault vault-init 2>/dev/null || true
kubectl delete secret -n vault vault-init-keys 2>/dev/null || true
cd deployments && ./initialize-vault.sh
```

**Flux Recovery:**
```bash
# Reinstall Flux
flux uninstall --silent
flux install
kubectl apply -f clusters/production/flux-sources.yaml
```

**External Secrets Recovery:**
```bash
# Restart External Secrets Operator
kubectl rollout restart deployment -n external-secrets-system external-secrets-operator
kubectl delete externalsecrets -A --all
flux reconcile kustomization production
```

## Monitoring and Diagnostics

### 15. Health Check Commands

```bash
# Overall cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running

# Component-specific health
kubectl exec -n vault vault-0 -- vault status
flux get all --all-namespaces
kubectl get externalsecrets -A

# Network connectivity
kubectl exec -n default -it busybox -- nslookup vault.vault.svc.cluster.local
kubectl exec -n default -it busybox -- wget -qO- http://vault.vault.svc.cluster.local:8200/v1/sys/health
```

### 16. Log Aggregation

```bash
# Collect logs from all critical components
mkdir -p /tmp/debug-logs
kubectl logs -n vault -l app.kubernetes.io/name=vault > /tmp/debug-logs/vault.log
kubectl logs -n flux-system -l app=source-controller > /tmp/debug-logs/flux-source.log
kubectl logs -n flux-system -l app=kustomize-controller > /tmp/debug-logs/flux-kustomize.log
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets > /tmp/debug-logs/external-secrets.log
kubectl logs -n cloudflared -l app=cloudflared > /tmp/debug-logs/cloudflared.log

# Archive for analysis
tar -czf debug-logs-$(date +%Y%m%d-%H%M%S).tar.gz /tmp/debug-logs/
```

## Getting Help

### 17. Useful Debugging Tools

```bash
# Install debugging tools
kubectl run debug --image=nicolaka/netshoot -it --rm -- bash

# DNS resolution testing
nslookup vault.vault.svc.cluster.local
dig @10.43.0.10 vault.vault.svc.cluster.local

# Network connectivity testing
telnet vault.vault.svc.cluster.local 8200
curl -v http://vault.vault.svc.cluster.local:8200/v1/sys/health

# Process and port inspection
ss -tlnp | grep :8200
ps aux | grep vault
```

### 18. Documentation References

- **Kubernetes Troubleshooting**: https://kubernetes.io/docs/tasks/debug/
- **Flux Documentation**: https://fluxcd.io/flux/
- **Vault Troubleshooting**: https://developer.hashicorp.com/vault/docs/troubleshoot
- **External Secrets Operator**: https://external-secrets.io/latest/
- **k3s Documentation**: https://k3s.io/

### 19. Community Support

- **GitHub Issues**: File issues in the respective repository
- **Kubernetes Community**: https://kubernetes.io/community/
- **CNCF Slack**: Join relevant channels for component-specific help