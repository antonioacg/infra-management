# GitOps Workflow Documentation

## Overview

This document explains how our phase-based GitOps implementation works, from code commit to production deployment, using Flux CD for continuous deployment and HashiCorp Vault for zero-secrets management. The five-phase bootstrap ensures proper dependency sequencing, and secrets flow from bootstrap environment variables through self-referencing Terraform to Vault, then automatically sync to Kubernetes via External Secrets Operator.

## GitOps Architecture

### Repository Structure
```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│ infra-management│    │   deployments    │    │      infra      │
│                 │    │                  │    │                 │
│ • Phase Bootstrap│───▶│ • K8s Manifests  │    │ • Terraform     │
│ • Orchestration │    │ • Flux Config    │    │ • Self-Reference│
│ • Documentation │    │ • App Deployments│    │ • Vault Secrets │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 ▼
                    ┌─────────────────────────┐
                    │ Kubernetes Cluster      │
                    │ (5-Phase Bootstrap)     │
                    │ ┌─────┐ ┌─────────────┐ │
                    │ │Flux │ │Vault +      │ │
                    │ │ CD  │ │External     │ │
                    │ │     │ │Secrets      │ │
                    │ └─────┘ └─────────────┘ │
                    └─────────────────────────┘
```

### Core Components

#### 1. Flux CD - GitOps Engine
- **Source Controller**: Monitors Git repositories for changes
- **Kustomize Controller**: Applies Kubernetes manifests
- **Helm Controller**: Manages Helm releases (if used)
- **No Secret Decryption**: Secrets handled entirely by External Secrets Operator

#### 2. External Secrets Operator - Secret Synchronization
- **ClusterSecretStore**: Connects to Vault for secret retrieval
- **ExternalSecret**: Defines which secrets to sync and where
- **SecretStore**: Namespace-specific secret store configuration

#### 3. HashiCorp Vault - Secret Management
- **KV Secrets Engine**: Stores application secrets populated by Terraform during bootstrap
- **Kubernetes Auth**: Authenticates cluster workloads (External Secrets Operator)
- **Auto-Unseal**: Automatic unsealing using Kubernetes-stored init keys

## GitOps Workflow

### 1. Development Phase
```bash
# Developer makes changes to application
git add .
git commit -m "feat: add new feature"
git push origin main
```

### 2. Deployment Repository Update
```bash
# Update Kubernetes manifests in deployments repo
cd deployments/
git add clusters/production/apps/myapp/
git commit -m "deploy: update myapp to v1.2.3"
git push origin main
```

### 3. Flux Synchronization
```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│    Git      │───▶│    Flux     │───▶│ Kubernetes  │
│ Repository  │    │Source       │    │   Cluster   │
│   Change    │    │Controller   │    │             │
└─────────────┘    └─────────────┘    └─────────────┘
```

**Automatic Process:**
1. **Source Controller** detects changes in `deployments` repository
2. **Fetches** updated manifests every 1 minute (configurable)
3. **Kustomize Controller** applies changes to cluster
4. **Health checks** verify deployment success
5. **Status** reported back to Git via commits/annotations

### 4. Five-Phase Secret Management Flow
```
Phase 1: Infrastructure Bootstrap
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│    k3s      │───▶│    Flux     │───▶│    Vault    │───▶│ External    │
│ Kubernetes  │    │   GitOps    │    │   Secret    │    │ Secrets     │
│   Cluster   │    │ Controller  │    │ Management  │    │ Operator    │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘

Phase 2: Secret Population (Bootstrap Environment Variables → Cleared)
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│Bootstrap    │───▶│Self-Ref     │───▶│    Vault    │
│ENV Variables│    │Terraform    │    │   Stores    │
│GITHUB_TOKEN │    │(Read/Write) │    │ALL Secrets  │
│CLOUDFLARE...|    │             │    │inc. Git Auth│
└─────────────┘    └─────────────┘    └─────────────┘
      │                     │                     
      │ [CLEARED]           │ Ongoing ops         
      ∅                     │ (no ENV needed)     

Phase 3: Flux Authentication Switch
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│    Vault    │───▶│ External    │───▶│ Flux Git    │
│GitHub Token │    │ Secret for  │    │ Auth Secret │
│   Stored    │    │ Git Auth    │    │  Created    │
└─────────────┘    └─────────────┘    └─────────────┘

Phase 4: Application Deployment (Working External Secrets)
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│    Vault    │───▶│ External    │───▶│ K8s Secret  │───▶│Application  │
│All App      │    │ Secrets     │    │   Created   │    │   Pods      │
│  Secrets    │    │ Operator    │    │(Cloudflared)│    │  Running    │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘

Phase 5: Verification & Cleanup
```

**Five-Phase Secret Lifecycle:**
1. **Phase 1**: Infrastructure deployment (k3s, Flux, Vault, External Secrets Operator)
2. **Phase 2**: Bootstrap environment variables → Terraform → Vault (ALL secrets including Git auth), then env vars cleared
3. **Phase 3**: Flux switches to External Secrets for Git authentication
4. **Phase 4**: External Secrets Operator syncs all application secrets automatically
5. **Phase 5**: Environment variables cleared, system verified, complete zero-secrets achieved

## Deployment Patterns

### Application Deployment
```yaml
# deployments/clusters/production/apps/myapp/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- deployment.yaml
- service.yaml
- ingress.yaml
- externalsecret.yaml

commonLabels:
  app: myapp
  version: v1.2.3
```

### External Secret Configuration
```yaml
# deployments/clusters/production/apps/myapp/externalsecret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secrets
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-secrets
    creationPolicy: Owner
  data:
  - secretKey: database-password
    remoteRef:
      key: secret/myapp
      property: db_password
```

### Terraform Secret Population
```hcl
# infra/envs/prod/secrets.tf
resource "vault_kv_secret_v2" "myapp" {
  mount = "secret"
  name  = "myapp"
  
  data_json = jsonencode({
    db_password = var.myapp_db_password
    api_key     = var.myapp_api_key
  })
}
```

## Operational Workflows

### New Application Deployment

1. **Create Application Manifests**
```bash
cd deployments/clusters/production/apps/
mkdir newapp
cd newapp
```

2. **Define Kubernetes Resources**
```yaml
# deployment.yaml, service.yaml, ingress.yaml
# externalsecret.yaml for secrets
```

3. **Update Kustomization**
```yaml
# deployments/clusters/production/kustomization.yaml
resources:
- apps/newapp
```

4. **Add Secrets to Terraform**
```hcl
# infra/envs/prod/secrets.tf
resource "vault_kv_secret_v2" "newapp" {
  mount = "secret"
  name  = "newapp"
  data_json = jsonencode({
    secret_key = var.newapp_secret  # From TF_VAR_newapp_secret env var
  })
}
```

5. **Apply Changes**
```bash
# Commit ExternalSecret to deployments repo
git add . && git commit -m "deploy: add newapp"
git push

# For new secrets, add to bootstrap environment variables and redeploy:
# export NEWAPP_SECRET="your_secret_value"
# Run bootstrap again (five-phase process handles this automatically)
# Or update manually via Terraform post-bootstrap
```

### Configuration Updates

#### Application Configuration
```bash
# Update deployment manifests
cd deployments/clusters/production/apps/myapp/
# Edit deployment.yaml, configmap.yaml, etc.
git commit -m "config: update myapp configuration"
git push
```

#### Secret Updates
```bash
# Update via Terraform (post-bootstrap)
cd infra/envs/prod/
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
export TF_VAR_updated_secret="new_secret_value"

kubectl port-forward -n vault svc/vault 8200:8200 &
terraform apply
kill %1  # Kill port-forward

# External Secrets Operator automatically syncs within 1 minute
```

### Rollback Procedures

#### Git-based Rollback
```bash
# Rollback deployment repository
cd deployments/
git revert <commit-hash>
git push

# Or reset to previous commit
git reset --hard <previous-commit>
git push --force-with-lease
```

#### Manual Intervention
```bash
# Suspend Flux reconciliation
flux suspend kustomization production

# Make manual changes
kubectl apply -f emergency-fix.yaml

# Resume Flux
flux resume kustomization production
```

## Monitoring and Observability

### Flux Status Monitoring
```bash
# Check overall GitOps status
flux get all --all-namespaces

# Check specific source
flux get sources git deployments

# Check kustomization status
flux get kustomizations production

# View reconciliation logs
flux logs --follow --all-namespaces
```

### Secret Synchronization Status
```bash
# Check External Secrets status
kubectl get externalsecrets -A

# Verify secret creation
kubectl get secrets -A | grep -v "kubernetes.io\|Opaque.*0"

# Check ClusterSecretStore connectivity
kubectl describe clustersecretstore vault-backend
```

### Application Health
```bash
# Check pod status
kubectl get pods -A | grep -v Running

# View application logs
kubectl logs -n <namespace> -l app=<appname> --tail=50

# Check ingress status
kubectl get ingress -A
```

## Security Considerations

### Secret Management Security
- **No secrets in Git**: All sensitive data stored in Vault
- **No command-line secrets**: Environment variables more secure than script arguments
- **Bootstrap-only secrets**: Environment variables only exist during initial deployment
- **RBAC**: External Secrets Operator has minimal required permissions
- **Network policies**: Restrict pod-to-pod communication

### GitOps Security
- **Branch protection**: Require PR reviews for production deployments
- **Signed commits**: Verify commit authenticity
- **Flux RBAC**: Limit Flux controller permissions
- **Namespace isolation**: Applications deployed in separate namespaces

### Access Control
```bash
# Vault policies restrict secret access
vault policy write myapp-policy - <<EOF
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
EOF

# Kubernetes RBAC limits service account permissions
kubectl create role myapp-secrets-reader --verb=get,list --resource=secrets
kubectl create rolebinding myapp-secrets-binding --role=myapp-secrets-reader --serviceaccount=myapp:myapp-service-account
```

## Troubleshooting

### Common Issues

#### Flux Not Synchronizing
```bash
# Check source repository connectivity
flux get sources git

# Check Flux controller logs
kubectl logs -n flux-system -l app=kustomize-controller

# Force reconciliation
flux reconcile source git deployments
flux reconcile kustomization production
```

#### External Secrets Not Working
```bash
# Check Vault connectivity
kubectl exec -n vault vault-0 -- vault status

# Verify service account authentication
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets

# Test ClusterSecretStore
kubectl describe clustersecretstore vault-backend
```

#### Application Deployment Failures
```bash
# Check resource events
kubectl describe deployment <app-name> -n <namespace>

# Verify image pull
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Check resource quotas
kubectl describe namespace <namespace>
```

### Debug Commands

```bash
# Complete cluster health check
./scripts/verify-deployment.sh

# Flux troubleshooting
flux check --verbose

# Vault connectivity test
kubectl port-forward -n vault svc/vault 8200:8200 &
curl -s http://localhost:8200/v1/sys/health | jq

# External Secrets debug
kubectl get externalsecrets -A -o yaml | grep -A5 -B5 status
```

## Performance Optimization

### Flux Configuration
```yaml
# Increase sync frequency for critical applications
spec:
  interval: 30s  # Default: 1m
  
# Batch changes for efficiency  
spec:
  dependsOn:
  - name: infrastructure
  - name: monitoring
```

### Resource Limits
```yaml
# Set appropriate resource limits
resources:
  limits:
    memory: "512Mi"
    cpu: "500m"
  requests:
    memory: "256Mi" 
    cpu: "250m"
```

### External Secrets Optimization
```yaml
# Reduce refresh frequency for stable secrets
spec:
  refreshInterval: 5m  # Default: 1m
  
# Use selective secret updates
spec:
  target:
    creationPolicy: Owner
    deletionPolicy: Retain
```

This GitOps workflow ensures reliable, secure, and scalable application deployment with complete zero-secrets architecture - no secrets in Git, no command-line arguments, only environment variables during bootstrap that automatically populate Vault for ongoing secret management via External Secrets Operator.