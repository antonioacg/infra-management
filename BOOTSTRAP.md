# Bootstrap Documentation

## Overview

Single-command bootstrap for deploying an enterprise-grade Kubernetes platform with secure secret management and GitOps capabilities.

**One Command:**
```bash
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small
```

**Current Status:** Phases 0-1 complete and validated. Phases 2-4 in development.

---

## 📋 Bootstrap Phases (Canonical Definitions)

### Phase 0: Environment & Tools

**Purpose:** Validate system requirements and install necessary tools without touching the cluster.

**What It Does:**
- System architecture detection (x86_64/ARM64, Linux/macOS)
- Tool installation: kubectl, terraform, helm, flux, yq, mc
- Environment validation (sudo access, network connectivity)
- GitHub token validation

**State Management:** No Terraform state (no infrastructure deployed).

**Success Criteria:**
- All required tools installed and accessible
- System meets minimum requirements
- GitHub token has correct scopes

---

### Phase 1: k3s + Bootstrap Storage

**Purpose:** Deploy foundation infrastructure with local state for bootstrapping.

**What It Does:**
- k3s cluster deployment with tier-based resource allocation
- Data-at-rest encryption (two-layer: etcd + LUKS)
  - etcd encryption for all Kubernetes secrets (all platforms)
  - LUKS container encryption for node storage (Linux only)
- MinIO S3-compatible storage (for future Terraform remote state)
- PostgreSQL database (for future state locking)
- Bootstrap namespace creation

**State Management:**
- LOCAL Terraform state in temporary directory (`/tmp/phase1-terraform-$$`)
- State preserved for migration in Phase 2

**Key Design Decisions:**
- Local state allows bootstrap without dependencies
- Temporary directory isolates bootstrap state
- Credentials generated in-memory only (no files)
- Two-layer encryption protects secrets before Vault deployment
- Tier-based scaling (small/medium/large) for enterprise readiness

**Success Criteria:**
- k3s cluster running and accessible via kubectl
- etcd encryption-at-rest enabled for all Kubernetes secrets
- LUKS container encryption active (Linux only)
- MinIO and PostgreSQL pods running in bootstrap namespace
- Credentials generated and preserved in memory for Phase 2

---

### Phase 2: Remote State + Vault Infrastructure

**Purpose:** Migrate to remote state and deploy core infrastructure services.

**Subphases:**

#### Phase 2a: Prerequisites & Validation
**What It Does:**
- Validates Phase 1 dependencies (MinIO and PostgreSQL running)
- Checks cluster accessibility
- Verifies bootstrap namespace exists

**Success Criteria:**
- MinIO service accessible and responding
- PostgreSQL cluster healthy
- kubectl can communicate with cluster

#### Phase 2b: Bootstrap State Migration
**What It Does:**
- Migrates Phase 1 Terraform state from LOCAL → REMOTE (MinIO S3 backend)
- Configures PostgreSQL state locking
- Establishes port-forward to MinIO for state operations
- Uses Phase 1 credentials preserved in memory

**Success Criteria:**
- Phase 1 state successfully migrated to MinIO backend
- State locking configured with PostgreSQL
- Backend configuration verified

#### Phase 2c: Infrastructure Deployment
**What It Does:**
- Clones `infra` repository and checks out specified git ref
- Deploys core secret management infrastructure in three steps to handle CRD dependencies

**Deployment Steps:**

**Step 1: Deploy Operators**
- Bank-Vaults operator (Helm chart - installs Vault CRDs)
- External Secrets operator (Helm chart - installs ESO CRDs)
- Uses Terraform targeted apply for operator Helm releases only

**Step 2: Wait for CRDs**
- Waits for Bank-Vaults CRDs to be registered in Kubernetes API
- Validates CRD availability before proceeding
- Ensures Terraform can validate custom resource manifests in next step

**Step 3: Deploy Custom Resources**
- Vault CR (custom resource managed by Bank-Vaults operator)
- External Secrets ClusterSecretStore and authentication
- Full Terraform apply for all remaining infrastructure resources

**Why Three Steps?**
Terraform validates `kubernetes_manifest` resources during `terraform plan` by querying the Kubernetes API server for CRD schemas. If CRDs don't exist yet (because operators haven't been deployed), the plan fails with "no matches for kind". The three-step approach ensures:
1. Operators are deployed and running
2. CRDs are registered in the API server
3. Terraform can successfully validate and deploy custom resources

**Step Validation:**
- `--stop-after=2c-step1`: Deploy operators only
- `--stop-after=2c-step2`: Deploy operators + wait for CRDs
- `--stop-after=2c-step3`: Full deployment (default)

**Success Criteria:**
- All operator Helm releases deployed successfully
- CRDs registered and available in Kubernetes API
- Vault CR created and managed by operator
- External Secrets resources deployed
- No Terraform state conflicts

#### Phase 2d: Validation & Cleanup
**What It Does:**
- Waits for Bank-Vaults operator pods to be ready
- Waits for Vault pods to be ready and unsealed
- Verifies Vault unseal keys secret created by operator
- Waits for External Secrets pods to be ready
- Validates ClusterSecretStore authentication to Vault
- Closes port-forwards and cleans up temporary resources

**Success Criteria:**
- Vault pods running and automatically unsealed
- External Secrets Operator connecting to Vault
- ClusterSecretStore authentication successful
- All infrastructure services healthy

**State Management:**
- Phase 1 state: Migrated to remote MinIO backend (Phase 2b)
- Phase 2 infrastructure: Deployed via `infra/` repository with remote state in MinIO
- PostgreSQL provides distributed state locking

**Key Design Decisions:**
- Bank-Vaults operator provides production-ready automated unsealing without Enterprise license or cloud dependencies (see `bank-vaults-design.md`)
- Three-step deployment handles CRD timing dependencies reliably
- External Secrets enables GitOps secret management (used in Phase 4)
- kubectl port-forward used for bootstrap access (no external networking)
- **Networking/Ingress deferred to Phase 4** (currently deployed due to legacy implementation, will be removed)

**Known Issues:**
- ⚠️ **Nginx Ingress module**: Currently deployed in Phase 2 due to legacy implementation attempts. This will be moved to Phase 4 where networking is actually needed. For now, it's deployed but not used.

**Overall Phase 2 Success Criteria:**
- Phase 1 state successfully migrated to MinIO
- Vault pods running and automatically unsealed on pod restart
- External Secrets Operator connecting to Vault
- ClusterSecretStore authentication successful
- State locking prevents concurrent operations

---

### Phase 3: Advanced Security (Planned)

**Purpose:** Configure advanced Vault features and security policies.

**What It Does:**
- Advanced Vault authentication backends (Kubernetes, AppRole, etc.)
- Vault policy configuration for least-privilege access
- Certificate management setup
- Security hardening and compliance configuration

**State Management:** REMOTE state in `infra/environments/production/`

**Success Criteria:**
- Vault policies configured for application access
- Authentication backends operational
- Certificate management ready for TLS

---

### Phase 4: GitOps (Planned)

**Purpose:** Enable GitOps-based application deployment mechanism.

**What It Does:**
- Flux GitOps controller deployment
- GitOps repository sync configuration (`deployments/` repository)
- Application deployment automation via Kustomize/Helm
- Infrastructure changes deployed via git commits

**State Management:** REMOTE state in `infra/environments/production/`

**Key Design Decisions:**
- GitOps uses External Secrets Operator for credential management
- Applications deployed via Flux reconciliation
- Declarative infrastructure via git as single source of truth
- No manual kubectl apply - everything via git

**Success Criteria:**
- Flux syncing from git repositories
- Kustomizations reconciling successfully
- Applications deployable via git commits to `deployments/` repository
- External Secrets synchronized to application namespaces

**Note:** Once Phase 4 is complete, all applications (Nginx Ingress, databases, services, jobs, etc.) will be deployed through GitOps, not through bootstrap phases.

---

## 🎯 Usage

### Full Bootstrap (All Phases)

```bash
# Single node, small resources (default)
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small

# Multi-node HA, medium resources
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=3 --tier=medium

# Enterprise scale, large resources
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=10 --tier=large
```

### Individual Phase Testing

**Phase 0:**
```bash
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase0.sh | GITHUB_TOKEN="test" bash -s -- --nodes=1 --tier=small
```

**Phase 1:** (requires Phase 0 completion)
```bash
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/bootstrap-phase1.sh | GITHUB_TOKEN="test" bash -s -- --nodes=1 --tier=small
```

**Phase 2:** (requires Phase 1 completion)
```bash
./scripts/bootstrap-phase2.sh --nodes=1 --tier=small --environment=production
```

### Start from Specific Phase

```bash
# Skip Phase 0 (tools already installed)
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small --start-phase=1

# Skip Phase 0-1 (foundation already deployed)
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small --start-phase=2
```

---

## 📋 Prerequisites

### System Requirements
- **OS:** Linux (Ubuntu, Debian, CentOS, Fedora, Arch)
- **Architecture:** x86_64 or ARM64
- **Memory:** 4GB+ RAM recommended
- **Storage:** 20GB+ available disk space
- **Network:** Internet connectivity required

### Required Access
- **GitHub Token:** Personal access token with `repo` and `workflow` scopes
  - Get token at: https://github.com/settings/tokens
- **sudo Access:** Required for:
  - Tool installation (kubectl, terraform, helm)
  - k3s cluster installation and service management
  - LUKS container encryption setup (Linux only)
  - etcd encryption configuration (root-owned files with 600 permissions)
  - Reading k3s kubeconfig (created with 600 permissions for security)

---

## 🏗️ Architecture Overview

### Repository Structure

**Three-Repository Architecture:**
- **infra-management/** - Bootstrap orchestration (this repository)
- **infra/** - Terraform infrastructure modules and environments
- **deployments/** - GitOps manifests and Flux configuration

### State Management Strategy

**Phase 1 (Bootstrap Foundation):**
- Location: `/tmp/phase1-terraform-$$` (temporary)
- Backend: LOCAL filesystem
- Purpose: Foundation only (k3s, MinIO, PostgreSQL)

**Phase 2+ (Infrastructure & Applications):**
- Location: `infra/environments/production/`
- Backend: REMOTE (MinIO S3 + PostgreSQL locking)
- Purpose: All infrastructure and application state

**Key Principle:** Clear separation between bootstrap foundation and infrastructure services.

### Scaling Strategy

**Resource Tiers:**
- **small:** 10Gi MinIO, 8Gi PostgreSQL
- **medium:** HA, 50Gi MinIO, 20Gi PostgreSQL
- **large:** Enterprise scale, 100Gi+ MinIO, 50Gi+ PostgreSQL

**Node Scaling:**
- `--nodes=1` - Single node deployment
- `--nodes=3` - HA deployment with quorum
- `--nodes=10+` - Enterprise scale

---

## 🔐 Security Model

### Credential Management

**Phase 1:**
- All credentials generated in-memory using OpenSSL
- No credential files created on disk
- Credentials preserved in memory for Phase 2 (from Phase 1)

**Phase 2:**
- Phase 1 credentials used for state migration
- Vault unseal keys and root token generated during initialization
- Root token used for bootstrap, then revoked
- All credentials cleared from memory after successful deployment

**Phase 3+:**
- All secrets managed via Vault
- External Secrets syncs secrets to Kubernetes
- GitOps applications access secrets via External Secrets

### Zero-Secrets Architecture

- **Git Repositories:** No secrets ever committed
- **Environment Variables:** Used only during bootstrap, then cleared
- **Secret Management:** Vault + External Secrets for all ongoing operations

---

## 🔍 Verification

### Phase 1 Verification
```bash
kubectl get nodes
kubectl get pods -n bootstrap
kubectl get pvc -n bootstrap
```

### Phase 2 Verification (when available)
```bash
# Vault status
kubectl get pods -n vault
kubectl port-forward -n vault svc/vault 8200:8200
curl http://localhost:8200/v1/sys/health

# External Secrets
kubectl get clustersecretstore vault-backend
kubectl get externalsecrets -A
```

### State Backend Access (Phase 2+)
```bash
# MinIO console
kubectl port-forward -n bootstrap svc/bootstrap-minio 9001:9001
# Access: http://localhost:9001
```

---

## 🐛 Troubleshooting

### General Approach
1. Check logs with increased verbosity: `LOG_LEVEL=DEBUG` or `LOG_LEVEL=TRACE`
2. Verify prerequisites are met for the phase
3. Check component-specific logs: `kubectl logs -n <namespace> <pod>`

### Phase 1 Issues

**k3s installation fails:**
- Check system requirements (architecture, OS, resources)
- Verify sudo access
- Review k3s logs: `journalctl -u k3s`

**Terraform deployment fails:**
- Verify credentials are generated (check script output)
- Check pod status: `kubectl get pods -n bootstrap`
- Review Terraform logs in temporary directory

### Phase 2 Issues (when available)

**State migration fails:**
- Verify MinIO accessibility: `kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000`
- Check Phase 1 temp directory still exists with terraform.tfstate
- Validate credentials are preserved from Phase 1

**Vault unsealing fails:**
- Check Bank-Vaults configurer sidecar logs: `kubectl logs -n vault vault-0 -c bank-vaults`
- Verify `vault-unseal-keys` K8s Secret exists: `kubectl get secret -n vault vault-unseal-keys`
- Check Bank-Vaults operator logs: `kubectl logs -n vault-operator -l app.kubernetes.io/name=vault-operator`
- Review Vault pod logs for initialization errors: `kubectl logs -n vault vault-0 -c vault`
- See break-glass recovery in `bank-vaults-design.md`

### Recovery Procedures

**Full cleanup and restart:**
```bash
# Clean up previous deployment
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/cleanup.sh | bash -s -- --force

# Run complete bootstrap (Phase 0 + Phase 1)
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small
```

**Development iteration (faster cycle):**
```bash
# Clean up k3s cluster only, preserve tools
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/scripts/cleanup.sh | bash -s -- --force --skip-phase0

# Run Phase 0 + Phase 1 (always run both)
curl -sfL https://raw.githubusercontent.com/${GITHUB_ORG:-antonioacg}/infra-management/${GIT_REF:-main}/bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small
```

**Important Notes:**
- Always run cleanup before testing/retrying
- Phase 0 must run before Phase 1 (dependency validation)
- Use `bootstrap.sh` for Phase 0-1, then continue with Phase 2+ (credentials in memory)

---

## 📚 Additional Documentation

**Implementation Details:**
- Phase 2 implementation plan: `bootstrap-phase2-plan.md`
- Operational procedures: `CLAUDE.md` (workspace-specific)

**Architecture:**
- Enterprise platform architecture: `ENTERPRISE_PLATFORM_ARCHITECTURE.md` (if exists)
