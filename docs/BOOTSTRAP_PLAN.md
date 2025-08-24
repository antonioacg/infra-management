# Zero-Secrets Bootstrap Plan

## Overview

This document outlines the complete implementation of zero secrets in Git for greenfield deployments. The approach uses a **phase-based bootstrap** with a **3-repository architecture**, External Secrets Operator, and self-referencing Terraform for enterprise-grade secret management with minimal operational complexity.

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
- ✅ Vault initialization and unsealing automation
- ✅ Simple bootstrap process from any machine
- ✅ Remote deployment capability
- ✅ Terraform infrastructure management

### Previous Limitations (Now Solved)
- ~~❌ Secrets still stored in Git~~ → ✅ Zero secrets in Git with External Secrets
- ~~❌ Manual secret management~~ → ✅ Automatic Vault → External Secrets sync
- ~~❌ Terraform secrets hardcoded~~ → ✅ Self-referencing Terraform patterns

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

## Phase-Based Bootstrap Implementation

### Five-Phase Bootstrap Architecture

The bootstrap process is organized into five sequential phases that ensure proper component dependencies and eliminate transient error states:

1. **Phase 1**: Core Infrastructure (k3s + Flux + Vault + External Secrets)
2. **Phase 2**: Secret Population (ALL secrets → Vault via Terraform)
3. **Phase 3**: Flux Authentication Switch (External Secrets for Git auth)
4. **Phase 4**: Application Deployment (working External Secrets)
5. **Phase 5**: Verification and Cleanup (security validation)

### External Secrets Operator Integration

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

## Unified Bootstrap Implementation

### Infra-Management Repository Structure
```
infra-management/
├── bootstrap.sh                    # Unified bootstrap script (environment variables only)
├── README.md                       # Quick start guide
├── docs/
│   ├── BOOTSTRAP_PLAN.md          # This document
│   ├── GITOPS_WORKFLOW.md         # GitOps workflow documentation
│   ├── SECRET_MANAGEMENT.md       # Zero-secrets architecture
│   ├── COMPONENT_INTERACTIONS.md  # System architecture diagrams
│   └── OPERATIONAL_PROCEDURES.md  # Daily operations and troubleshooting
└── scripts/
    └── verify-deployment.sh       # Post-bootstrap verification
```

### Phase-Based Bootstrap Script

The `infra-management/bootstrap.sh` implements the five-phase architecture with environment variables for maximum security:

```bash
#!/bin/bash
set -e

# Zero-Secrets Phase-Based Bootstrap Orchestrator
# Implements complete zero-secrets architecture with proper sequencing

# Required environment variables (only needed during bootstrap)
required_vars=(
    "GITHUB_TOKEN"
    "CLOUDFLARE_TUNNEL_TOKEN"
)

main() {
    echo "🚀 Zero-Secrets Phase-Based Bootstrap Orchestrator"
    echo "Architecture: Environment Variables → Terraform → Vault → External Secrets → Kubernetes"
    
    validate_environment
    
    # Phase 1: Infrastructure Bootstrap
    log_phase "1" "Core Infrastructure (k3s + Flux + Vault + External Secrets)"
    install_k3s
    install_tools
    deploy_infrastructure_phase    # Only infrastructure components
    wait_for_vault_ready
    
    # Phase 2: Secret Population
    log_phase "2" "Populate ALL secrets in Vault via Terraform"
    populate_vault_with_all_secrets  # Including GitHub token
    
    # Phase 3: Flux External Secrets Authentication
    log_phase "3" "Switch Flux to External Secrets authentication"
    deploy_flux_auth_phase          # External Secret for GitHub token
    
    # Phase 4: Application Deployment
    log_phase "4" "Deploy applications with working External Secrets"
    deploy_applications_phase       # External Secrets work immediately
    
    # Phase 5: Verification & Cleanup
    log_phase "5" "Verification and cleanup"
    verify_all_phases
    cleanup_bootstrap_secrets       # Remove env vars, clean workspace
    
    echo "✅ Zero-Secrets Phase-Based Bootstrap completed successfully!"
    echo "🔒 Security: All bootstrap secrets cleared from environment"
    echo "🏛️  Secret Management: All secrets now managed through Vault + External Secrets"
}

deploy_infrastructure_phase() {
    # Bootstrap Flux with direct GitHub authentication (temporary)
    flux bootstrap git \
        --url="$DEPLOYMENTS_REPO" \
        --branch=main \
        --path=clusters/production/infrastructure \
        --token-auth
}

populate_vault_with_all_secrets() {
    # Connect to Vault and populate ALL secrets including GitHub token
    export TF_VAR_github_token="$GITHUB_TOKEN"              # For Flux
    export TF_VAR_cloudflare_tunnel_token="$CLOUDFLARE_TUNNEL_TOKEN"
    
    terraform init && terraform apply -auto-approve
}

deploy_flux_auth_phase() {
    # Deploy External Secret for GitHub token and restart Flux controllers
    flux reconcile source git flux-system
    kubectl rollout restart deployment -n flux-system
}

cleanup_bootstrap_secrets() {
    # Clear ALL bootstrap secrets from environment
    for var in "${required_vars[@]}"; do
        unset "$var" 2>/dev/null || true
    done
    
    # Clear TF_VAR_* variables
    for var in $(env | grep "^TF_VAR_" | cut -d= -f1); do
        unset "$var" 2>/dev/null || true
    done
}

main "$@"
```

### Ultra-Simple Bootstrap Command

```bash
# From any machine with SSH access to fresh Ubuntu server:
ssh user@new-server

# Set environment variables (more secure than command-line arguments)
export GITHUB_TOKEN="ghp_your_github_token_here"
export CLOUDFLARE_TUNNEL_TOKEN="your_cloudflare_tunnel_token_here"

# Single command bootstrap (all five phases automatic)
curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | bash
```

Or as a one-liner:
```bash
GITHUB_TOKEN="ghp_xxx" \
CLOUDFLARE_TUNNEL_TOKEN="eyJhxxx" \
curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | bash

# Bootstrap automatically handles:
# Phase 1: k3s + Flux + Vault + External Secrets
# Phase 2: ALL secrets → Vault (including GitHub token)
# Phase 3: Flux switches to External Secrets auth
# Phase 4: Applications deploy with working secrets
# Phase 5: Verification + environment cleanup
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

## Secret Management Workflow

### Adding New Secrets (Greenfield)

1. **Add to bootstrap environment variables:**
```bash
# When running bootstrap, include new secrets
export GITHUB_TOKEN="ghp_xxx"
export CLOUDFLARE_TUNNEL_TOKEN="eyJh"
export NEW_APP_DB_PASSWORD="secure_password"  # New secret
```

2. **Define in Terraform with self-referencing pattern:**
```hcl
# Self-referencing pattern for ongoing operations
data "vault_kv_secret_v2" "existing_app" {
  count = var.new_app_db_password == "" ? 1 : 0
  mount = "secret"
  name  = "myapp/database"
}

resource "vault_kv_secret_v2" "new_app_secrets" {
  mount = "secret"
  path  = "myapp/database"
  data_json = jsonencode({
    username = "myapp_user"
    password = var.new_app_db_password != "" ? var.new_app_db_password : data.vault_kv_secret_v2.existing_app[0].data["password"]
  })
}
```

3. **Create ExternalSecret in deployments repository:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-db-secrets
  namespace: myapp
spec:
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-db-secrets
  data:
  - secretKey: DB_USERNAME
    remoteRef:
      key: secret/myapp/database
      property: username
  - secretKey: DB_PASSWORD
    remoteRef:
      key: secret/myapp/database
      property: password
```

4. **Deployment Flow:**
- Bootstrap populates secrets in Vault (Phase 2)
- Applications deploy with working External Secrets (Phase 4)
- No transient error states

### Ongoing Secret Updates (Post-Bootstrap)

```bash
# Self-referencing Terraform works without environment variables
cd infra/envs/prod
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(kubectl get secret -n vault vault-init-keys -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)"

# Option 1: Update existing secret (reads from Vault)
kubectl port-forward -n vault svc/vault 8200:8200 &
terraform apply  # Uses existing values from Vault
kill %1

# Option 2: Provide new value via environment variable  
export TF_VAR_new_app_db_password="updated_password"
kubectl port-forward -n vault svc/vault 8200:8200 &
terraform apply  # Uses new value, updates Vault
kill %1

# External Secrets Operator automatically syncs within 1 minute
```

## Greenfield Implementation Steps

Since this is a greenfield deployment with no legacy constraints, implementation is straightforward:

### Step 1: Create Repository Structure
1. Create `infra-management` repository with unified bootstrap script
2. Ensure `deployments` repository has External Secrets Operator manifests
3. Ensure `infra` repository has Terraform Vault secret resources

### Step 2: Prepare Secrets
1. Collect all required secrets (GitHub token, Cloudflare tunnel token, etc.)
2. Set as environment variables before running bootstrap

### Step 3: Execute Bootstrap
1. Run single bootstrap command with environment variables
2. Bootstrap automatically handles: k3s → Flux → Vault unsealing → secret population
3. Verify all applications start successfully

### Step 4: Operational Readiness
1. Test secret updates via Terraform
2. Verify External Secrets synchronization
3. Document operational procedures

## Operational Benefits

### Security
- ✅ Zero secrets in Git repository
- ✅ Centralized secret management via Vault
- ✅ Automatic secret rotation capabilities
- ✅ Audit trail for all secret access

### Simplicity
- ✅ Single environment variable bootstrap command (five phases automatic)
- ✅ No command-line secrets (environment variables are more secure)
- ✅ Self-referencing Terraform (works with or without environment variables)
- ✅ Automatic secret synchronization via External Secrets
- ✅ Zero-secrets architecture with zero transient error states

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

## Vault Unseal Keys Security Assessment

### Kubernetes Secret Storage Approach

**Current Implementation:**
- Vault unseal keys stored in Kubernetes secret `vault-init-keys`
- Keys are base64 encoded by default (not encrypted at rest)
- Accessible via Kubernetes RBAC controls

**Security Considerations:**
- ✅ **Acceptable for greenfield single-node k3s deployments**
- ✅ **Proper RBAC limits access to authorized service accounts**
- ✅ **Keys only exist during bootstrap and normal operations**
- ✅ **Can be enhanced with Kubernetes encryption at rest**

### Recommended Security Enhancements

1. **Enable Kubernetes Encryption at Rest:**
```yaml
# /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: <base64-encoded-key>
  - identity: {}
```

2. **Node-Level Security:**
- Encrypted disk storage
- Restricted node SSH access
- Regular security updates

3. **Future Cloud Auto-Unseal:**
- Migrate to cloud KMS auto-unseal when scaling
- AWS KMS, GCP Cloud KMS, Azure Key Vault integration
- Eliminates need for stored unseal keys

## Conclusion

This phase-based environment variable bootstrap achieves enterprise-grade zero-secrets-in-Git while maintaining maximum operational simplicity for greenfield deployments. The implementation provides:

- **Five-Phase Bootstrap**: Proper sequencing eliminates transient error states and ensures reliable deployment
- **True Zero Secrets**: No secrets in Git repositories or command-line arguments, all secrets cleared from environment post-bootstrap
- **Complete Secret Flow**: Environment Variables → Terraform → Vault → External Secrets → Kubernetes → Applications (including Flux Git auth)
- **Self-Referencing Terraform**: Works with or without environment variables for ongoing operations
- **Enhanced Security**: Vault auto-unsealing with Kubernetes secret storage and comprehensive environment cleanup
- **Operational Excellence**: Single command deploys entire stack with proper dependency management

The phase-based approach eliminates operational complexity while providing enterprise-grade security and reliability. This creates the optimal deployment experience for greenfield zero-secrets infrastructure with proper component dependencies and no legacy migration complexity.