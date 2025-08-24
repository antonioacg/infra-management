# Operational Procedures

## Overview

This document provides comprehensive operational procedures for managing the phase-based zero-secrets GitOps infrastructure, including daily operations, maintenance tasks, incident response, and emergency procedures. All secrets flow through the five-phase bootstrap: Environment Variables → Terraform → Vault → External Secrets → Kubernetes.

## Daily Operations

### Morning Health Checks

```bash
#!/bin/bash
# daily-health-check.sh

echo "🌅 Daily GitOps Health Check - $(date)"
echo "=========================================="

# 1. Cluster Health
echo "📊 Cluster Status:"
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed | grep -v Succeeded

# 2. GitOps Status  
echo -e "\n🔄 Flux Status:"
flux get all --all-namespaces

# 3. Secret Synchronization
echo -e "\n🔐 External Secrets Status:"
kubectl get externalsecrets -A

# 4. Vault Health
echo -e "\n🏦 Vault Status:"
kubectl exec -n vault vault-0 -- vault status

# 5. Ingress Status
echo -e "\n🌐 Ingress Status:"
kubectl get ingress -A

# 6. Resource Usage
echo -e "\n💾 Resource Usage:"
kubectl top nodes 2>/dev/null || echo "Metrics server not available"
kubectl top pods -A --sort-by=memory 2>/dev/null | head -10

echo -e "\n✅ Health check completed at $(date)"
```

### Monitoring Commands

```bash
# Quick status overview
alias k8s-status='kubectl get pods -A | grep -v Running'
alias flux-status='flux get all --all-namespaces'  
alias vault-status='kubectl exec -n vault vault-0 -- vault status'
alias secret-status='kubectl get externalsecrets -A'

# Resource monitoring
alias top-pods='kubectl top pods -A --sort-by=memory'
alias top-nodes='kubectl top nodes'

# Log monitoring
alias flux-logs='kubectl logs -n flux-system -l app=source-controller --tail=50'
alias vault-logs='kubectl logs -n vault -l app.kubernetes.io/name=vault --tail=50'
alias external-secrets-logs='kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets --tail=50'
```

## Application Deployment Procedures

### 1. New Application Deployment

#### Pre-deployment Checklist
- [ ] Application container image built and pushed
- [ ] Database migrations prepared (if applicable)
- [ ] Secrets defined in Terraform
- [ ] Kubernetes manifests created
- [ ] Ingress configuration prepared
- [ ] Resource limits defined
- [ ] Health checks configured

#### Deployment Steps

**Step 1: Prepare Secrets**
```bash
# Navigate to infrastructure
cd infra/envs/prod/

# Add new secrets to Terraform
cat >> secrets.tf << EOF
resource "vault_kv_secret_v2" "newapp" {
  mount = "secret"
  name  = "newapp"
  
  data_json = jsonencode({
    database_url = var.newapp_database_url
    api_key     = var.newapp_api_key
  })
}
EOF

# Add variables
cat >> variables.tf << EOF
variable "newapp_database_url" {
  description = "Database URL for newapp"
  type        = string
  sensitive   = true
}

variable "newapp_api_key" {
  description = "API key for newapp"
  type        = string
  sensitive   = true
}
EOF

# For new secrets during ongoing operations (post-bootstrap):
# Method 1: Environment variables (preferred for new secrets)
export TF_VAR_newapp_database_url="postgresql://user:pass@db:5432/newapp"
export TF_VAR_newapp_api_key="secret_api_key_value"

# Method 2: Self-referencing Terraform (reads existing values from Vault)
# No environment variables needed if secrets already exist

# Apply infrastructure changes
terraform apply
```

**Step 2: Create Kubernetes Manifests**
```bash
# Navigate to deployments
cd deployments/clusters/production/apps/

# Create application directory
mkdir newapp
cd newapp

# Create namespace
cat > namespace.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: newapp
  labels:
    name: newapp
EOF

# Create external secret
cat > externalsecret.yaml << EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: newapp-secrets
  namespace: newapp
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: newapp-secrets
    creationPolicy: Owner
  data:
  - secretKey: DATABASE_URL
    remoteRef:
      key: secret/newapp
      property: database_url
  - secretKey: API_KEY
    remoteRef:
      key: secret/newapp
      property: api_key
EOF

# Create deployment
cat > deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: newapp
  namespace: newapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: newapp
  template:
    metadata:
      labels:
        app: newapp
    spec:
      containers:
      - name: newapp
        image: myregistry/newapp:v1.0.0
        ports:
        - containerPort: 8080
        envFrom:
        - secretRef:
            name: newapp-secrets
        resources:
          limits:
            memory: "512Mi"
            cpu: "500m"
          requests:
            memory: "256Mi"
            cpu: "250m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
EOF

# Create service
cat > service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: newapp
  namespace: newapp
spec:
  selector:
    app: newapp
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
EOF

# Create ingress
cat > ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: newapp
  namespace: newapp
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: newapp.aac.gd
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: newapp
            port:
              number: 80
EOF

# Create kustomization
cat > kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- namespace.yaml
- externalsecret.yaml
- deployment.yaml
- service.yaml
- ingress.yaml

commonLabels:
  app: newapp
  managed-by: flux
EOF
```

**Step 3: Add to Main Kustomization**
```bash
# Update main kustomization
cd ../..  # Back to clusters/production/
cat >> kustomization.yaml << EOF
- apps/newapp
EOF
```

**Step 4: Deploy**
```bash
# Commit ExternalSecret to deployments repo
git add .
git commit -m "deploy: add newapp application with external secrets"
git push origin main

# For new secrets (post-bootstrap via self-referencing Terraform)
cd infra/envs/prod/
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"

# Option 1: Provide new secret via environment variable
export TF_VAR_newapp_secret="your_secret_value"

# Option 2: Use existing value from Vault (no env var needed)
# Self-referencing Terraform will read existing values automatically

kubectl port-forward -n vault svc/vault 8200:8200 &
terraform apply
kill %1

# Monitor deployment
watch kubectl get pods -n newapp
```

**Step 5: Verify Deployment**
```bash
# Check deployment status
kubectl get deployment newapp -n newapp

# Verify secrets are created
kubectl get secrets -n newapp

# Check external secret status
kubectl get externalsecret newapp-secrets -n newapp

# Test application endpoint
curl -H "Host: newapp.aac.gd" http://localhost/health

# Check logs
kubectl logs -n newapp -l app=newapp --tail=50
```

### 2. Application Updates

#### Rolling Updates
```bash
# Update deployment manifest
cd deployments/clusters/production/apps/newapp/
sed -i 's/v1.0.0/v1.1.0/g' deployment.yaml

# Commit and push
git add deployment.yaml
git commit -m "update: bump newapp to v1.1.0"
git push origin main

# Monitor rollout
kubectl rollout status deployment newapp -n newapp
kubectl get pods -n newapp -w
```

#### Configuration Updates
```bash
# Update configmap or environment variables
# Edit deployment.yaml or create configmap.yaml

git add .
git commit -m "config: update newapp configuration"
git push origin main

# Force deployment restart if needed
kubectl rollout restart deployment newapp -n newapp
```

### 3. Secret Updates

#### Update Application Secrets
```bash
# Update secrets via Terraform
cd infra/envs/prod/
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
export TF_VAR_newapp_api_key="new_secret_value"

# Apply changes
kubectl port-forward -n vault svc/vault 8200:8200 &
terraform apply
kill %1

# Verify external secrets sync (automatic within 1 minute)
kubectl get externalsecret newapp-secrets -n newapp -w

# Force immediate sync if needed
kubectl annotate externalsecret newapp-secrets -n newapp \
  force-sync="$(date +%s)"

# Restart application to pick up new secrets
kubectl rollout restart deployment newapp -n newapp
```

## Maintenance Procedures

### 1. Cluster Maintenance

#### Node Updates
```bash
# Drain node for maintenance
kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data

# Perform system updates on the node
ssh node-1 'sudo apt update && sudo apt upgrade -y && sudo reboot'

# Wait for node to rejoin cluster
kubectl get nodes -w

# Uncordon node
kubectl uncordon node-1
```

#### Kubernetes Component Updates
```bash
# Update k3s (example)
ssh cluster-node 'curl -sfL https://get.k3s.io | sh -'

# Verify cluster health after update
kubectl get nodes
kubectl get pods -A
```

### 2. GitOps Component Maintenance

#### Flux Updates
```bash
# Check current Flux version
flux version

# Update Flux CLI
curl -s https://fluxcd.io/install.sh | sudo bash

# Update Flux controllers
flux install --export > flux-system.yaml
kubectl apply -f flux-system.yaml

# Verify update
flux get all --all-namespaces
```

#### Vault Maintenance
```bash
# Backup Vault data
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /tmp/vault-backup.snap
kubectl cp vault/vault-0:/tmp/vault-backup.snap ./vault-backup-$(date +%Y%m%d).snap

# Update Vault (if needed)
# This typically involves updating the Helm chart or manifest versions

# Verify Vault health
kubectl exec -n vault vault-0 -- vault status
```

### 3. Monitoring and Alerting Maintenance

#### Log Rotation
```bash
# Clean up old logs
kubectl delete pods -l app=completed-jobs --field-selector=status.phase=Succeeded

# Rotate application logs (if using persistent volumes)
kubectl exec -n myapp myapp-pod -- logrotate /etc/logrotate.conf
```

## Incident Response Procedures

### 1. Service Outage Response

#### Immediate Response (0-5 minutes)
```bash
# Step 1: Assess the situation
kubectl get pods -A | grep -v Running
kubectl get nodes
curl -I https://app.aac.gd/health

# Step 2: Check recent deployments
flux get all --all-namespaces | grep -i fail
git log --oneline -10

# Step 3: Quick fixes
# Restart failed pods
kubectl delete pod <failed-pod> -n <namespace>

# Scale up if needed
kubectl scale deployment <app> --replicas=5 -n <namespace>
```

#### Investigation (5-30 minutes)
```bash
# Check logs
kubectl logs -n <namespace> -l app=<app> --tail=100

# Check events
kubectl get events -n <namespace> --sort-by=.metadata.creationTimestamp

# Check resource usage
kubectl top pods -A
kubectl describe node <node-name>

# Check external dependencies
kubectl exec -n <namespace> <pod> -- nslookup external-service.com
kubectl exec -n <namespace> <pod> -- curl -I https://api.external.com
```

#### Resolution (30+ minutes)
```bash
# Rollback if deployment caused the issue
git revert <commit-hash>
git push origin main

# Or suspend Flux and apply emergency fix
flux suspend kustomization production
kubectl apply -f emergency-fix.yaml
# Resume after fix is confirmed
flux resume kustomization production

# Scale resources if needed
kubectl patch deployment <app> -n <namespace> -p '{"spec":{"resources":{"limits":{"memory":"1Gi","cpu":"1000m"}}}}'
```

### 2. Security Incident Response

#### Suspected Breach
```bash
# Step 1: Isolate affected resources
kubectl patch deployment <app> -n <namespace> -p '{"spec":{"replicas":0}}'

# Step 2: Preserve evidence
kubectl logs -n <namespace> <pod> > incident-logs-$(date +%Y%m%d-%H%M%S).log
kubectl get events -A > incident-events-$(date +%Y%m%d-%H%M%S).log

# Step 3: Rotate secrets immediately
cd infra/envs/prod/
# Update all sensitive values in terraform.tfvars
terraform apply -var-file=terraform.tfvars

# Force secret sync
kubectl get externalsecrets -A -o name | xargs -I {} kubectl annotate {} force-sync="$(date +%s)"

# Step 4: Review access logs
kubectl exec -n vault vault-0 -- vault audit list
```

### 3. Data Recovery Procedures

#### Vault Data Recovery
```bash
# Restore from backup
kubectl cp ./vault-backup-20231201.snap vault/vault-0:/tmp/vault-restore.snap
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/vault-restore.snap

# Verify data integrity
kubectl exec -n vault vault-0 -- vault kv list secret/
```

#### Application Data Recovery
```bash
# Restore from external backup (database, etc.)
kubectl exec -n myapp myapp-pod -- pg_restore -h database -U user backup.sql

# Verify data restoration
kubectl exec -n myapp myapp-pod -- psql -h database -U user -c "SELECT COUNT(*) FROM users;"
```

## Emergency Procedures

### 1. Complete Cluster Failure

#### Bootstrap New Cluster (Five-Phase Process)
```bash
# On new Ubuntu machine - set bootstrap environment variables
export GITHUB_TOKEN="ghp_your_token"
# Only GITHUB_TOKEN required - all other secrets auto-generated by Terraform

# Run five-phase bootstrap (all phases automatic)
curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | bash

# Five phases executed automatically:
# Phase 1: Core Infrastructure (k3s + Flux + Vault + External Secrets)
# Phase 2: Secret Population (ALL secrets → Vault via Terraform)
# Phase 3: Flux Authentication Switch (External Secrets for Git auth)
# Phase 4: Application Deployment (working External Secrets)
# Phase 5: Verification & Cleanup (environment variables cleared)
```

#### Restore Data
```bash
# Restore Vault data
kubectl cp vault-backup.snap vault/vault-0:/tmp/restore.snap
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/restore.snap

# Verify applications come up with restored secrets
kubectl get pods -A
```

### 2. Git Repository Corruption

#### Emergency Git Recovery
```bash
# Clone from backup or fork
git clone https://github.com/antonioacg/deployments-backup.git deployments
cd deployments

# Update repository URL in Flux
flux create source git deployments \
  --url=https://github.com/antonioacg/deployments-backup.git \
  --branch=main \
  --namespace=flux-system

# Verify synchronization
flux get sources git
```

### 3. Network Connectivity Issues

#### Cloudflare Tunnel Failure
```bash
# Check tunnel status
kubectl logs -n cloudflared -l app=cloudflared

# Restart tunnel
kubectl rollout restart deployment cloudflared -n cloudflared

# Verify tunnel connectivity
curl -H "Host: app.aac.gd" http://nginx-ingress-controller.ingress-nginx.svc.cluster.local
```

#### Internal DNS Issues
```bash
# Test DNS resolution
kubectl run dns-test --image=busybox --restart=Never -- nslookup kubernetes.default

# Check CoreDNS
kubectl logs -n kube-system -l k8s-app=kube-dns

# Restart CoreDNS if needed
kubectl rollout restart deployment coredns -n kube-system
```

## Backup and Recovery

### 1. Regular Backup Procedures

#### Daily Backups
```bash
#!/bin/bash
# daily-backup.sh

BACKUP_DATE=$(date +%Y%m%d)

# Backup Vault
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /tmp/vault-$BACKUP_DATE.snap
kubectl cp vault/vault-0:/tmp/vault-$BACKUP_DATE.snap ./backups/vault-$BACKUP_DATE.snap

# Backup Git repositories (already in Git, but create archives)
git clone https://github.com/antonioacg/deployments.git
tar -czf backups/deployments-$BACKUP_DATE.tar.gz deployments/
rm -rf deployments/

# Backup Terraform state
cd infra/envs/prod/
terraform state pull > ../../../backups/terraform-state-$BACKUP_DATE.json

# Upload to external storage (S3, etc.)
aws s3 sync ./backups/ s3://my-backup-bucket/k8s-backups/
```

#### Weekly Full Backups
```bash
#!/bin/bash
# weekly-backup.sh

# Full cluster backup using Velero (if installed)
velero backup create weekly-backup-$(date +%Y%m%d)

# Export all Kubernetes resources
kubectl get all --all-namespaces -o yaml > k8s-full-backup-$(date +%Y%m%d).yaml
```

### 2. Testing Recovery Procedures

#### Monthly Recovery Tests
```bash
# Test Vault backup/restore
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /tmp/test-backup.snap
# ... simulate failure ...
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/test-backup.snap

# Verify all applications still work
./scripts/verify-deployment.sh
```

This operational documentation ensures smooth day-to-day operations and quick response to incidents while maintaining the security and reliability of the phase-based zero-secrets GitOps infrastructure. All secret management flows through the five-phase bootstrap process: Environment Variables (bootstrap-only) → Terraform (self-referencing) → Vault → External Secrets → Kubernetes, with complete environment cleanup for maximum security.