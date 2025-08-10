# Zero-Secrets Bootstrap Plan

## Overview

This document outlines the plan to achieve zero secrets in Git while maintaining maximum operational simplicity. The approach uses a **3-repository architecture** with External Secrets Operator + Terraform + curl|bash bootstrap for enterprise-grade secret management with minimal complexity.

## 3-Repository Architecture

### Repository Structure

1. **`infra-management`** - Bootstrap orchestrator and documentation
   - Master bootstrap script that coordinates other repositories
   - Comprehensive documentation and troubleshooting guides
   - Tool installation and verification scripts
   - Ultra-simple `curl | bash` entry point

2. **`infra`** - Terraform infrastructure code (existing)
   - Vault configuration and secret management
   - Infrastructure provisioning and state management
   - Environment-specific configurations

3. **`deployments`** - Kubernetes GitOps manifests (existing)
   - Flux configuration and Kubernetes resources
   - External Secrets Operator setup
   - Application deployments

### Benefits
- **Separation of Concerns**: Bootstrap logic separate from infrastructure and applications
- **Reusability**: Bootstrap script works with different infra/deployment combinations
- **Simplicity**: Single entry point while maintaining modular architecture
- **Security**: Bootstrap repo contains no secrets, only orchestration logic
- **Flexibility**: Easy to swap infrastructure or deployment strategies

## Current State Analysis

### What Works Well
- ✅ GitOps deployment with Flux
- ✅ SOPS + Age encryption for secrets
- ✅ Remote deployment via `./install.sh` + kubectl context
- ✅ Vault initialization and unsealing automation
- ✅ Simple bootstrap process from any machine

### Current Limitations
- ❌ Secrets still stored in Git (encrypted, but present)
- ❌ Manual secret management via SOPS files
- ❌ Terraform secrets hardcoded in tfvars

## Target Architecture

### Secret Flow
```
Developer Machine → Terraform → Vault → External Secrets Operator → Kubernetes Secrets → Applications
```

### Key Components
1. **Vault**: Centralized secret storage with Kubernetes auth
2. **External Secrets Operator**: Automatic sync from Vault to Kubernetes
3. **Terraform**: Declarative secret management in Vault
4. **Flux**: GitOps deployment (unchanged)

## Implementation Plan

### Phase 1: External Secrets Operator Integration

#### Add to GitOps Repository
```
deployments/clusters/production/external-secrets/
├── namespace.yaml
├── helm-repository.yaml  
├── helm-release.yaml
├── cluster-secret-store.yaml
├── rbac.yaml
└── kustomization.yaml
```

#### Sample External Secrets Configuration
```yaml
# deployments/clusters/production/external-secrets/cluster-secret-store.yaml
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
            name: external-secrets-operator
            namespace: external-secrets-system
```

### Phase 2: Replace SOPS Secrets with External Secrets

#### Remove from Git
- `deployments/clusters/production/cloudflared/cloudflared-credentials.sops.yaml`

#### Add External Secret Definition
```yaml
# deployments/clusters/production/cloudflared/external-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cloudflared-credentials
  namespace: cloudflared
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: cloudflared-credentials
    creationPolicy: Owner
  data:
  - secretKey: token
    remoteRef:
      key: cloudflare/tunnel
      property: token
```

### Phase 3: Terraform Secret Management

#### Enhanced Terraform Configuration
```hcl
# infra/envs/prod/variables.tf
variable "cloudflare_tunnel_token" {
  description = "Cloudflare tunnel token"
  type        = string
  sensitive   = true
}

variable "vault_secrets" {
  description = "Map of secrets to store in Vault"
  type = map(map(string))
  default = {}
  sensitive = true
}

# infra/modules/vault/main.tf
resource "vault_kv_secret_v2" "cloudflare_tunnel" {
  mount = vault_mount.kv.path
  path  = "cloudflare/tunnel"
  data = {
    token = var.cloudflare_tunnel_token
  }
}

# Generic secret management for future expansion
resource "vault_kv_secret_v2" "secrets" {
  for_each = var.vault_secrets
  mount    = vault_mount.kv.path
  path     = each.key
  data     = each.value
}
```

## Bootstrap Implementation

### Infra-Management Repository Structure
```
infra-management/
├── bootstrap.sh                    # Master bootstrap script
├── README.md                       # Quick start guide
├── docs/
│   ├── BOOTSTRAP_PLAN.md          # This document (moved from ops repo)
│   ├── TROUBLESHOOTING.md         # Common issues and solutions
│   └── ARCHITECTURE.md            # System architecture overview
├── scripts/
│   ├── install-tools.sh           # Tool installation helpers
│   └── verify-deployment.sh       # Post-bootstrap verification
└── config/
    └── repositories.yaml          # Repository URLs and configurations
```

### Master Bootstrap Script
Create `infra-management/bootstrap.sh`:

```bash
#!/bin/bash
set -e

# Parse arguments
GITHUB_TOKEN="$1"
SOPS_AGE_KEY="$2"
CLOUDFLARE_TUNNEL_TOKEN="$3"

# Configuration
DEPLOYMENTS_REPO="https://github.com/antonioacg/deployments.git"
INFRA_REPO="https://github.com/antonioacg/infra.git"
WORKSPACE="/tmp/bootstrap-workspace"

echo "🚀 Starting zero-secrets bootstrap..."
echo "📁 Creating workspace: $WORKSPACE"
mkdir -p $WORKSPACE
cd $WORKSPACE

# 1. Install k3s
echo "📦 Installing k3s..."
curl -sfL https://get.k3s.io | sh -
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 2. Setup environment
echo "⚙️ Setting up environment..."
mkdir -p ~/.config/sops/age/
echo "$SOPS_AGE_KEY" > ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
export GITHUB_TOKEN="$GITHUB_TOKEN"

# 3. Clone and deploy GitOps stack
echo "📥 Cloning deployments repository..."
git clone $DEPLOYMENTS_REPO deployments
cd deployments
echo "🔧 Deploying GitOps stack..."
./install.sh
cd ..

# 4. Wait for Vault to be ready
echo "⏳ Waiting for Vault to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s

# 5. Clone infra repository and setup Terraform
echo "📥 Cloning infrastructure repository..."
git clone $INFRA_REPO infra
cd infra/envs/prod

echo "🔐 Populating secrets via Terraform..."
# Port-forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &
VAULT_PF_PID=$!
sleep 5

# Setup Vault connection
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"

# Set Terraform variables
export TF_VAR_cloudflare_tunnel_token="$CLOUDFLARE_TUNNEL_TOKEN"

# Run Terraform
terraform init
terraform apply -auto-approve

# Cleanup
kill $VAULT_PF_PID
cd $WORKSPACE

# 6. Verification
echo "🔍 Running post-deployment verification..."
kubectl get externalsecrets -A 2>/dev/null || echo "External Secrets not yet deployed"
flux get all --all-namespaces
kubectl get pods -A | grep -E "(vault|cloudflared|external-secrets)"

echo "✅ Bootstrap complete! All secrets are now managed via Vault and External Secrets Operator."
echo "🧹 Cleaning up workspace..."
rm -rf $WORKSPACE
```

### Ultra-Simple Bootstrap Command

```bash
# From any machine with SSH access to fresh Ubuntu server:
ssh user@new-server
curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \
  bash -s \
  "github_token_here" \
  "$(cat ~/.config/sops/age/keys.txt)" \
  "cloudflare_tunnel_token_here"
```

### Repository Configuration
Create `infra-management/config/repositories.yaml`:
```yaml
repositories:
  deployments:
    url: "https://github.com/antonioacg/deployments.git"
    branch: "main"
    install_script: "./install.sh"
    description: "Kubernetes GitOps manifests and Flux configuration"
  
  infra:
    url: "https://github.com/antonioacg/infra.git"
    branch: "main"
    terraform_path: "envs/prod"
    description: "Terraform infrastructure and Vault secret management"

bootstrap:
  workspace: "/tmp/bootstrap-workspace"
  timeout: 600  # seconds
  verify_commands:
    - "kubectl get pods -A"
    - "flux get all --all-namespaces"
    - "kubectl get externalsecrets -A"
```

## Future Secret Management Workflow

### Adding New Secrets

1. **Define in Terraform:**
```hcl
resource "vault_kv_secret_v2" "new_app_secrets" {
  mount = vault_mount.kv.path
  path  = "myapp/database"
  data = {
    username = var.db_username
    password = var.db_password
  }
}
```

2. **Create ExternalSecret:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-db-secrets
spec:
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-db-secrets
  data:
  - secretKey: username
    remoteRef:
      key: myapp/database
      property: username
```

3. **Deploy via GitOps:**
- Commit ExternalSecret to Git
- Flux automatically deploys
- External Secrets Operator syncs from Vault

### Secret Updates

```bash
# Update secrets via Terraform
cd infra/envs/prod
export TF_VAR_new_secret_value="updated_value"
terraform apply
# External Secrets Operator automatically syncs changes
```

## Migration Steps from Current Setup

### Step 1: Prepare External Secrets Operator
1. Add External Secrets manifests to GitOps repository
2. Update main kustomization.yaml to include external-secrets
3. Commit and let Flux deploy

### Step 2: Migrate Cloudflared Secret
1. Add cloudflared ExternalSecret manifest
2. Update Terraform to include cloudflare/tunnel secret
3. Remove cloudflared-credentials.sops.yaml from Git
4. Run Terraform to populate Vault

### Step 3: Verify and Clean Up
1. Verify cloudflared pod uses synced secret
2. Remove SOPS encrypted files from Git
3. Update documentation and workflows

## Operational Benefits

### Security
- ✅ Zero secrets in Git repository
- ✅ Centralized secret management via Vault
- ✅ Automatic secret rotation capabilities
- ✅ Audit trail for all secret access

### Simplicity
- ✅ One-command bootstrap from fresh machine
- ✅ Declarative secret management via Terraform
- ✅ Automatic secret synchronization
- ✅ No manual SOPS encryption/decryption

### Scalability
- ✅ Easy to add new applications and secrets
- ✅ Environment-specific secret management
- ✅ Integration with CI/CD pipelines
- ✅ Support for dynamic secrets

## Troubleshooting Guide

### Common Issues

#### External Secrets Not Syncing
```bash
# Check External Secrets Operator logs
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets

# Verify ClusterSecretStore
kubectl get clustersecretstore vault-backend -o yaml

# Check ExternalSecret status
kubectl describe externalsecret cloudflared-credentials -n cloudflared
```

#### Vault Authentication Issues
```bash
# Verify Vault Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth list

# Check service account permissions
kubectl get clusterrolebinding | grep external-secrets
```

#### Bootstrap Failures
```bash
# Check Flux reconciliation
flux get all --all-namespaces

# Verify Vault status
kubectl exec -n vault vault-0 -- vault status

# Check Terraform state
cd infra/envs/prod
terraform show
```

## Security Considerations

### Key Management
- Age private keys must remain on operator machines only
- Vault unseal keys stored in Kubernetes secrets with proper RBAC
- Regular rotation of Vault tokens and keys

### Access Control
- Least privilege access for External Secrets Operator service account
- Vault policies restrict access to specific secret paths
- Kubernetes RBAC controls secret access within cluster

### Network Security
- Vault communication over cluster-internal network
- External Secrets Operator authenticates via Kubernetes service account
- No external network access required for secret synchronization

## Future Enhancements

### Advanced Secret Management
- Implement Vault secret rotation policies
- Add support for dynamic database credentials
- Integrate with cloud provider secret managers

### Automation Improvements  
- GitHub Actions integration for Terraform runs
- Automated testing of bootstrap procedures
- Disaster recovery automation

### Monitoring and Alerting
- Prometheus metrics for secret sync health
- Alerts for failed secret synchronizations
- Dashboard for secret management operations

## Migration from Current Setup

### Step 1: Create Infra-Management Repository
1. Create new GitHub repository: `infra-management`
2. Move `BOOTSTRAP_PLAN.md` from ops repository to `infra-management/docs/`
3. Create master bootstrap script as shown above
4. Add repository configuration and helper scripts

### Step 2: Update Repository References
1. Update deployments repository URL in bootstrap script
2. Ensure infra repository is accessible and properly structured
3. Test bootstrap script with new 3-repo architecture

### Step 3: Enhance Documentation
1. Create `infra-management/README.md` with quick start guide
2. Add `TROUBLESHOOTING.md` for common issues
3. Create `ARCHITECTURE.md` with system overview
4. Update existing repository documentation to reference bootstrap repo

## Conclusion

This refined 3-repository architecture achieves enterprise-grade zero-secrets-in-Git while maintaining operational simplicity. The separation of concerns provides:

- **Bootstrap Orchestration**: Single entry point via `infra-management`
- **Infrastructure Management**: Terraform and Vault configuration via `infra`  
- **Application Deployment**: Kubernetes manifests and GitOps via `deployments`

The curl|bash bootstrap approach provides maximum ease of use, while External Secrets Operator and Terraform provide scalable, declarative secret management across the distributed repository architecture.