# Secret Management Documentation

## Overview

This document details how secrets are managed in our phase-based zero-secrets GitOps architecture. No secrets are stored in Git repositories or passed via command line - instead, they flow from bootstrap environment variables through self-referencing Terraform to Vault, then to Kubernetes via the External Secrets Operator.

## Secret Management Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     PHASE-BASED ZERO-SECRETS FLOW                             │
└─────────────────────────────────────────────────────────────────────────────────┘

   Bootstrap ENV      Self-Referencing       HashiCorp           External           Kubernetes
   Variables          Terraform               Vault              Secrets            Application
      │                     │                   │                  │                   │
      │ Phase 2 only       │                   │                  │                   │
      │ (cleared after)    │                   │                  │                   │
      │────────────────────▶│                   │                  │                   │
      │                     │ vault_kv_secret   │                  │                   │
      │                     │──────────────────▶│                  │                   │
      │                     │ (or read existing)│ Store encrypted  │                   │
      │                     │◀──────────────────│─────────────────▶│                   │
      │                     │                   │                  │ Poll every 1min   │
      │                     │                   │                  │◀──────────────────│
      │                     │                   │ Return secrets   │                   │
      │                     │                   │─────────────────▶│                   │
      │                     │                   │                  │ Create K8s Secret │
      │                     │                   │                  │──────────────────▶│
   [CLEARED]                │                   │                  │                   │ Mount as
      ∅                     │ Ongoing ops       │                  │                   │ env vars
                            │ (no ENV needed)   │                  │                   │ or volumes
```

## Components Deep Dive

### 1. HashiCorp Vault Configuration

#### Vault Setup
```yaml
# vault-config.yaml (deployed via Flux)
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: vault
data:
  vault.hcl: |
    ui = true
    
    listener "tcp" {
      address = "0.0.0.0:8200"
      tls_disable = true
    }
    
    storage "s3" {
      endpoint = "http://minio.minio.svc.cluster.local:9000"
      bucket = "vault-storage"
      s3_force_path_style = true
    }
    
    seal "auto" {
      type = "shamir"
      threshold = 1
      shares = 1
    }
```

#### Vault Authentication Methods
```bash
# Kubernetes authentication (configured during bootstrap)
vault auth enable kubernetes

vault write auth/kubernetes/config \
    token_reviewer_jwt="$(kubectl get secret vault-auth-secret -o jsonpath='{.data.token}' | base64 -d)" \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert="$(kubectl get secret vault-auth-secret -o jsonpath='{.data.ca\.crt}' | base64 -d)"

# External Secrets service account role
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets-operator \
    bound_service_account_namespaces=external-secrets-system \
    policies=external-secrets-policy \
    ttl=24h
```

#### Vault Policies
```hcl
# external-secrets-policy
path "secret/data/*" {
  capabilities = ["read"]
}

path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
```

### 2. External Secrets Operator Configuration

#### ClusterSecretStore
```yaml
# cluster-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets-operator"
            namespace: "external-secrets-system"
```

#### ExternalSecret Example
```yaml
# external-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secrets
  namespace: myapp
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-secrets
    creationPolicy: Owner
    deletionPolicy: Delete
  data:
  - secretKey: database-url
    remoteRef:
      key: secret/myapp/database
      property: connection_string
  - secretKey: api-key
    remoteRef:
      key: secret/myapp/external-api
      property: api_key
  - secretKey: jwt-secret
    remoteRef:
      key: secret/myapp/auth
      property: jwt_signing_key
```

### 3. Terraform Secret Management

#### Secret Resource Definition
```hcl
# infra/envs/prod/secrets.tf
resource "vault_kv_secret_v2" "myapp_database" {
  mount = "secret"
  name  = "myapp/database"
  
  data_json = jsonencode({
    connection_string = var.myapp_database_url
    username         = var.myapp_database_user
    password         = var.myapp_database_password
  })
}

resource "vault_kv_secret_v2" "myapp_external_api" {
  mount = "secret"
  name  = "myapp/external-api"
  
  data_json = jsonencode({
    api_key    = var.myapp_external_api_key
    secret_key = var.myapp_external_api_secret
  })
}

resource "vault_kv_secret_v2" "myapp_auth" {
  mount = "secret"
  name  = "myapp/auth"
  
  data_json = jsonencode({
    jwt_signing_key = var.myapp_jwt_secret
  })
}
```

#### Terraform Variables
```hcl
# infra/envs/prod/variables.tf
variable "myapp_database_url" {
  description = "Database connection string for myapp"
  type        = string
  sensitive   = true
}

variable "myapp_database_user" {
  description = "Database username for myapp"
  type        = string
  sensitive   = true
}

variable "myapp_database_password" {
  description = "Database password for myapp"
  type        = string
  sensitive   = true
}

variable "myapp_external_api_key" {
  description = "External API key for myapp"
  type        = string
  sensitive   = true
}
```

#### Self-Referencing Terraform Pattern
```hcl
# Read existing secrets from Vault for ongoing operations
data "vault_kv_secret_v2" "existing_myapp" {
  count = var.myapp_database_password == "" ? 1 : 0
  mount = "secret"
  name  = "myapp/database"
}

# Use either new value (if provided) or existing value from Vault
resource "vault_kv_secret_v2" "myapp_database" {
  mount = "secret"
  name  = "myapp/database"
  
  data_json = jsonencode({
    database_url = var.myapp_database_url != "" ? var.myapp_database_url : data.vault_kv_secret_v2.existing_myapp[0].data["database_url"]
    database_user = var.myapp_database_user != "" ? var.myapp_database_user : data.vault_kv_secret_v2.existing_myapp[0].data["database_user"]
    database_password = var.myapp_database_password != "" ? var.myapp_database_password : data.vault_kv_secret_v2.existing_myapp[0].data["database_password"]
    external_api_key = var.myapp_external_api_key != "" ? var.myapp_external_api_key : data.vault_kv_secret_v2.existing_myapp[0].data["external_api_key"]
  })
}

# This pattern allows Terraform to work with OR without environment variables
```

## Secret Lifecycle Management

### 1. Adding New Secrets

#### Step 1: Define in Terraform
```hcl
# infra/envs/prod/secrets.tf
resource "vault_kv_secret_v2" "newapp_config" {
  mount = "secret"
  name  = "newapp/config"
  
  data_json = jsonencode({
    database_url = var.newapp_database_url
    redis_url    = var.newapp_redis_url
    secret_key   = var.newapp_secret_key
  })
}
```

#### Step 2: Add Variables
```hcl
# infra/envs/prod/variables.tf
variable "newapp_database_url" {
  description = "Database URL for newapp"
  type        = string
  sensitive   = true
}
```

#### Step 3: Set Values
```bash
# For new deployments, add to bootstrap environment variables
export NEWAPP_DATABASE_URL="postgresql://newapp:password@db:5432/newapp"
export NEWAPP_REDIS_URL="redis://redis:6379/1" 
export NEWAPP_SECRET_KEY="randomly-generated-secret-key"

# Bootstrap script automatically converts to TF_VAR_* format
```

#### Step 4: Apply Infrastructure
```bash
# During bootstrap, this is automatic
# For post-bootstrap updates:
cd infra/envs/prod/
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
kubectl port-forward -n vault svc/vault 8200:8200 &
terraform apply
kill %1
```

#### Step 5: Create ExternalSecret
```yaml
# deployments/clusters/production/apps/newapp/externalsecret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: newapp-config
  namespace: newapp
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: newapp-config
    creationPolicy: Owner
  data:
  - secretKey: DATABASE_URL
    remoteRef:
      key: secret/newapp/config
      property: database_url
  - secretKey: REDIS_URL
    remoteRef:
      key: secret/newapp/config
      property: redis_url
  - secretKey: SECRET_KEY
    remoteRef:
      key: secret/newapp/config
      property: secret_key
```

#### Step 6: Reference in Deployment
```yaml
# deployments/clusters/production/apps/newapp/deployment.yaml
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
        envFrom:
        - secretRef:
            name: newapp-config
        # Or individual environment variables:
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: newapp-config
              key: DATABASE_URL
```

### 2. Updating Existing Secrets

#### Update via Terraform
```bash
# For existing infrastructure, update secrets directly
cd infra/envs/prod/
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
export TF_VAR_myapp_api_key="new_api_key_value"

kubectl port-forward -n vault svc/vault 8200:8200 &
terraform apply
kill %1  # Kill port-forward
```

#### Automatic Synchronization
The External Secrets Operator will automatically detect changes in Vault and update the corresponding Kubernetes secrets within the refresh interval (default: 1 minute).

### 3. Secret Rotation

#### Manual Rotation
```bash
# Update secret in Vault via Terraform
cd infra/envs/prod/
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"
export TF_VAR_rotated_secret="new_rotated_value"

kubectl port-forward -n vault svc/vault 8200:8200 &
terraform apply
kill %1

# Force immediate sync (optional)
kubectl annotate externalsecret myapp-secrets -n myapp \
  force-sync="$(date +%s)"

# Restart deployments to pick up new secrets
kubectl rollout restart deployment myapp -n myapp
```

#### Automated Rotation (Future Enhancement)
```yaml
# external-secret-with-rotation.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secrets
spec:
  refreshInterval: 5m  # Check more frequently for rotated secrets
  target:
    name: myapp-secrets
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        annotations:
          reloader.stakater.com/match: "true"  # Auto-restart pods
```

## Security Best Practices

### 1. Access Control

#### Vault Policies by Environment
```hcl
# Production environment policy
path "secret/data/prod/*" {
  capabilities = ["read"]
}

# Staging environment policy  
path "secret/data/staging/*" {
  capabilities = ["read"]
}

# Development environment policy
path "secret/data/dev/*" {
  capabilities = ["read", "create", "update", "delete"]
}
```

#### Kubernetes RBAC
```yaml
# external-secrets-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-secrets-operator
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create", "update", "delete", "get", "list", "watch"]
- apiGroups: ["external-secrets.io"]
  resources: ["externalsecrets", "secretstores", "clustersecretstores"]
  verbs: ["get", "list", "watch"]
```

### 2. Secret Validation

#### Schema Validation
```yaml
# external-secret-with-validation.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: validated-secrets
spec:
  target:
    name: validated-secrets
    template:
      type: Opaque
      data:
        config.yaml: |
          database_url: "{{ .database_url }}"
          api_key: "{{ .api_key }}"
          # Validate format
          {{- if not (regexMatch "^postgresql://" .database_url) }}
          {{- fail "database_url must be a PostgreSQL connection string" }}
          {{- end }}
```

### 3. Audit and Monitoring

#### Vault Audit Logging
```hcl
# Enable audit logging in Vault
vault audit enable file file_path=/vault/logs/audit.log
```

#### External Secrets Monitoring
```bash
# Monitor External Secret status
kubectl get externalsecrets -A -w

# Check for synchronization errors
kubectl get events --field-selector reason=SecretSyncError -A

# View External Secrets Operator logs
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets
```

## Troubleshooting

### Common Issues

#### 1. External Secret Not Syncing
```bash
# Check External Secret status
kubectl describe externalsecret myapp-secrets -n myapp

# Common causes:
# - Incorrect Vault path or key
# - Authentication failure
# - Network connectivity issues
# - Vault policy restrictions

# Debug steps:
kubectl get clustersecretstore vault-backend -o yaml
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets
```

#### 2. Vault Authentication Issues
```bash
# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Test Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth -method=kubernetes role=external-secrets

# Verify service account token
kubectl get secret -n external-secrets-system \
  $(kubectl get serviceaccount external-secrets-operator -n external-secrets-system -o jsonpath='{.secrets[0].name}') \
  -o jsonpath='{.data.token}' | base64 -d
```

#### 3. Secret Not Appearing in Pod
```bash
# Check if Kubernetes secret exists
kubectl get secrets -n myapp

# Verify secret contents (be careful with sensitive data)
kubectl get secret myapp-secrets -n myapp -o yaml

# Check pod environment variables
kubectl exec -n myapp myapp-pod-xxx -- env | grep -i secret

# Restart deployment to pick up new secrets
kubectl rollout restart deployment myapp -n myapp
```

### Debug Commands

#### Vault Operations
```bash
# Port-forward to Vault (for local debugging)
kubectl port-forward -n vault svc/vault 8200:8200 &

# Set Vault environment
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"

# List secrets
vault kv list secret/

# Read specific secret
vault kv get secret/myapp/config

# Test Kubernetes authentication
vault write -field=token auth/kubernetes/login \
  role=external-secrets \
  jwt="$(kubectl get secret -n external-secrets-system external-secrets-token -o jsonpath='{.data.token}' | base64 -d)"
```

#### External Secrets Debugging
```bash
# Force refresh of External Secret
kubectl annotate externalsecret myapp-secrets -n myapp \
  force-sync="$(date +%s)"

# Check External Secret events
kubectl get events -n myapp --field-selector involvedObject.name=myapp-secrets

# Validate ClusterSecretStore connectivity
kubectl get clustersecretstore vault-backend -o jsonpath='{.status.conditions[0].message}'
```

## Phase-Based Secret Workflow

### Bootstrap Process (Phase 2: Secret Population)
```bash
# Step 1: Set environment variables (bootstrap only)
export GITHUB_TOKEN="ghp_your_token"
export CLOUDFLARE_TUNNEL_TOKEN="your_tunnel_token" 
export DATABASE_PASSWORD="secure_db_password"
# ... other secrets

# Step 2: Run phase-based bootstrap
curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | bash

# Step 3: Five-phase bootstrap automatically:
# Phase 1: Infrastructure (k3s, Flux, Vault, External Secrets)
# Phase 2: Secret population (ALL secrets → Vault including GitHub token)
# Phase 3: Flux auth switch (External Secrets for Git authentication)
# Phase 4: Application deployment (working External Secrets)
# Phase 5: Verification and cleanup (environment secrets cleared)
```

### Ongoing Operations (Self-Referencing Terraform)
```bash
# Post-bootstrap: Terraform works without environment variables
cd infra/envs/prod
terraform apply  # Reads existing values from Vault

# Or provide new values via environment variables when needed
export TF_VAR_database_password="new_password"
terraform apply  # Updates Vault with new value
```

### Result: Complete Zero-Secrets Architecture
```yaml
# Git repositories contain only ExternalSecret definitions
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secrets
  namespace: myapp
spec:
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-secrets
  data:
  - secretKey: database-password
    remoteRef:
      key: secret/myapp/config
      property: database_password
  - secretKey: api-key
    remoteRef:
      key: secret/myapp/config  
      property: api_key
```

### Benefits of Phase-Based Approach
1. **No secrets in Git** - Ever, anywhere
2. **No command-line secrets** - Environment variables only during bootstrap
3. **Complete environment cleanup** - All secrets cleared post-bootstrap
4. **Self-referencing Terraform** - Works with or without environment variables
5. **Phase-based reliability** - No transient error states
6. **External Secrets sync** - Including Flux Git authentication

This approach provides enterprise-grade secret management with operational simplicity and complete zero-secrets architecture.