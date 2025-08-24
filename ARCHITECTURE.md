# Zero-Secrets GitOps Architecture

## Overview

This is a **5-phase bootstrap architecture** that solves the fundamental "chicken-and-egg" problem of secret management: you need secrets to deploy secret management infrastructure, but you want all secrets managed by that infrastructure.

**Key Innovation**: Phase-based approach with automatic handoff eliminates transient error states while achieving complete zero-secrets architecture.

## The Secret Management Problem

Traditional GitOps approaches face the chicken-and-egg problem:

1. **Git repositories need secrets** for applications
2. **Secret management tools** need to be deployed first  
3. **Deployment tools need secrets** to access Git repositories
4. **Result**: Circular dependency

## Our Solution: 5-Phase Bootstrap

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

Phase 3: Flux Authentication Switch (CRITICAL HANDOFF)
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

Phase 5: Verification & Cleanup (Zero-Secrets Achieved)
```

## Phase-by-Phase Breakdown

### Phase 1: Infrastructure Bootstrap
**Goal**: Deploy core infrastructure with direct GitHub authentication

**Components Deployed**:
- **k3s Kubernetes cluster** (lightweight, universal)
- **Flux GitOps controllers** (using bootstrap GitHub token)
- **Vault secret management** (with auto-unseal)
- **External Secrets Operator** (ready but not yet active)

**Authentication**: Flux uses bootstrap GitHub token directly

**Duration**: ~2 minutes

### Phase 2: Secret Population  
**Goal**: Move ALL secrets from environment variables to Vault

**Process**:
1. Bootstrap environment variables are converted to Terraform variables
2. **Self-referencing Terraform** reads existing secrets OR uses new environment variables
3. **ALL secrets stored in Vault** including the GitHub token Flux is currently using
4. Environment variables are cleared immediately after successful Terraform apply

**Critical Insight**: This includes the GitHub token that Flux is actively using

**Duration**: ~1 minute

### Phase 3: Flux Authentication Switch (MOST CRITICAL)
**Goal**: Switch Flux from environment token to External Secrets without breaking it

**Critical Handoff Process**:
1. **Validate** External Secrets can authenticate to Vault
2. **Verify** GitHub token exists in Vault and has correct format  
3. **Deploy** External Secret that reads GitHub token from Vault
4. **Wait** for External Secret to create Kubernetes secret
5. **Backup** current Flux GitRepository configuration
6. **Switch** Flux to use External Secret instead of bootstrap token
7. **Test** Git access with new authentication
8. **Rollback** if switch fails (automatic)

**Risk Mitigation**: Complete rollback capability prevents permanent Flux breakage

**Duration**: ~1 minute

### Phase 4: Application Deployment
**Goal**: Deploy applications with External Secrets working automatically

**Process**:
- Applications deploy using External Secret definitions
- All application secrets sync automatically from Vault
- No manual secret management required

**Result**: Working GitOps pipeline with zero secrets in Git

**Duration**: ~1 minute

### Phase 5: Verification & Cleanup
**Goal**: Verify zero-secrets achievement and clean environment

**Verification Checks**:
- ✅ Flux using External Secrets for Git authentication
- ✅ GitHub token in Vault (not environment)  
- ✅ External Secrets syncing properly
- ✅ Applications running with External Secret-provided secrets
- ✅ Bootstrap environment variables cleared
- ✅ No secrets in Git repositories
- ✅ Platform completely self-contained

**Security Achievement**: True zero-secrets architecture

**Duration**: ~30 seconds

## Key Architecture Benefits

### 1. Eliminates Transient Error States
Traditional approaches have periods where:
- External Secrets deployed but Vault not populated (errors)
- Applications deployed but secrets not available (failures)
- Secret handoffs cause temporary authentication failures

**Our solution**: Phase-based approach ensures each component is fully ready before next phase

### 2. Infrastructure Independence
**Universal Compatibility**:
- Raspberry Pi 4 (4GB+) to enterprise cloud
- Same bootstrap command produces identical results
- Hardware-aware resource sizing
- Network-adaptive configurations

### 3. Self-Referencing Terraform
**Ongoing Operations Pattern**:
```hcl
# Works with or without environment variables
data "vault_kv_secret_v2" "existing_github" {
  count = var.github_token == "" ? 1 : 0
  mount = "secret"
  name  = "github/auth"
}

resource "vault_kv_secret_v2" "github_auth" {
  mount = "secret"
  path  = "github/auth"
  
  data_json = jsonencode({
    token = var.github_token != "" ? var.github_token : try(
      data.vault_kv_secret_v2.existing_github[0].data["token"], 
      ""
    )
  })
}
```

**Benefits**:
- **Bootstrap**: Uses environment variables
- **Ongoing ops**: Reads existing values from Vault
- **No dependency**: On environment variables after bootstrap

### 4. Complete Zero-Secrets Achievement

**What "Zero-Secrets" Means**:
- ✅ **Git repositories**: No secrets ever (vs. encrypted SOPS approach)
- ✅ **Command line**: No secret arguments (vs. traditional bootstrap scripts)  
- ✅ **Environment variables**: Cleared automatically after bootstrap
- ✅ **Configuration files**: No hardcoded secrets (vs. traditional GitOps)
- ✅ **Platform state**: Completely self-contained

**Security Model**: All ongoing secret access through Vault → External Secrets → Kubernetes

## 3-Repository Architecture

### 1. infra-management (Bootstrap Orchestrator)
- **Purpose**: Coordinates the 5-phase bootstrap process
- **Contains**: Bootstrap script, documentation, validation tools
- **Secrets**: None (only orchestration logic)
- **Usage**: Single entry point for deployment

### 2. infra (Infrastructure as Code)
- **Purpose**: Terraform configuration for Vault and secret management
- **Contains**: Self-referencing Terraform patterns, Vault configuration
- **Secrets**: None (reads from environment variables or existing Vault)
- **Usage**: Called automatically during Phase 2

### 3. deployments (GitOps Manifests)  
- **Purpose**: Kubernetes manifests and Flux configuration
- **Contains**: External Secret definitions, application deployments
- **Secrets**: None (all via External Secrets)
- **Usage**: Monitored by Flux for continuous deployment

## Security Guarantees

### During Bootstrap (Temporary)
- Environment variables used only during Phase 2
- Variables cleared immediately after Terraform apply
- No secrets in command-line arguments (more secure than traditional)
- Workspace automatically cleaned up

### After Bootstrap (Permanent)
- Zero secrets in any Git repository
- Zero secrets in environment variables
- All secrets managed through Vault → External Secrets
- Flux authentication via External Secrets (not bootstrap token)
- Platform operates independently without bootstrap dependencies

### Ongoing Operations
- Add secrets: Via Terraform (reads existing from Vault)
- Update secrets: Via Terraform or Vault directly
- Application secrets: Automatic sync via External Secrets
- No manual secret management required

## Comparison with Traditional Approaches

| Approach | Secrets in Git | Env Vars | Handoff Risk | Transient Errors | Infrastructure Independence |
|----------|----------------|----------|--------------|------------------|----------------------------|
| **SOPS + Age** | ❌ Encrypted | ❌ Permanent | ⚠️ Manual | ❌ High | ❌ Limited |
| **Sealed Secrets** | ❌ Encrypted | ❌ Permanent | ⚠️ Manual | ❌ High | ❌ Limited |  
| **Our 5-Phase** | ✅ Zero | ✅ Cleared | ✅ Automatic | ✅ Zero | ✅ Universal |

## Platform Vision

**Universal GitOps Infrastructure**: Same bootstrap command produces identical secure infrastructure whether deployed on:
- Development: Raspberry Pi cluster
- Staging: Cloud VMs  
- Production: Enterprise Kubernetes

**Economic Optimization**: Run development on $400 Pi cluster, scale to cloud only when needed. Same security model, same operational procedures.

**Infrastructure Independence**: True vendor independence with deployment flexibility based on cost/performance requirements rather than technical constraints.