# Bootstrap Documentation

Single-command bootstrap for a Flux-first GitOps platform.

```bash
curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \
  GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small
```

---

## Bootstrap Phases

### Phase 0: Environment & Tools

Validate system and install required tools.

**What It Does**:
- System detection (x86_64/ARM64, Linux)
- Tool installation (kubectl, terraform, helm, flux, yq)
- Environment validation (sudo, network)
- GitHub token validation

**State**: None (no infrastructure deployed)

---

### Phase 1: Foundation

Deploy k3s and bootstrap storage with LOCAL state.

**What It Does**:
- k3s cluster with data-at-rest encryption
  - etcd encryption for all Kubernetes secrets
  - LUKS container encryption (Linux only)
- MinIO S3 storage (Terraform state backend)
- PostgreSQL database (state locking)
- Bootstrap namespace

**State**: LOCAL (`/tmp/bootstrap-state`)

**Key Design**:
- Local state allows bootstrap without dependencies
- Credentials generated in-memory only (no files)
- Tier-based scaling from Day 1

**Verification**:
```bash
kubectl get nodes
kubectl get pods -n bootstrap
kubectl get pvc -n bootstrap
```

---

### Phase 2: Flux Bootstrap

Migrate state and install Flux for GitOps.

**What It Does**:
- State migration (LOCAL → MinIO remote backend)
- Configure PostgreSQL state locking
- Flux controllers installation
- GitOps repository sync (`deployments/` repo)

**State**: REMOTE (MinIO S3 + PostgreSQL locking)

**Key Design**:
- Flux manages all post-bootstrap infrastructure
- No CRD timing issues (Flux handles ordering naturally)
- Phase 1 credentials cleared after state migration

**Verification**:
```bash
flux get sources git
flux get kustomizations -A
```

---

### Phase 3+: GitOps Managed

Everything after Flux is deployed via GitOps.

**Managed by Flux (deployments/ repo)**:
- Vault with Bank-Vaults operator (auto-unseal)
- External Secrets Operator
- Ingress controllers
- Applications

**Key Design**:
- All changes via git commits
- Flux reconciles resources in correct order
- No more Terraform after Phase 2

---

## Usage

### Full Bootstrap

```bash
# Single node, small tier
curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \
  GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small

# Multi-node HA
curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \
  GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=3 --tier=medium
```

### Incremental Testing

```bash
--stop-after=0    # Phase 0 only
--stop-after=1    # Phase 0+1
--stop-after=2    # Full bootstrap
--start-phase=1   # Skip Phase 0
--start-phase=2   # Skip Phase 0+1
```

---

## Prerequisites

### System Requirements

- **OS**: Linux (Ubuntu, Debian, CentOS, Fedora, Arch)
- **Architecture**: x86_64 or ARM64
- **Memory**: 4GB+ RAM
- **Storage**: 20GB+ disk
- **Network**: Internet connectivity

### Required Access

- **GitHub Token**: `repo` and `workflow` scopes ([Get token](https://github.com/settings/tokens))
- **sudo Access**: For tool installation, k3s, encryption setup

---

## Scaling

| Tier | MinIO | PostgreSQL | Use Case |
|------|-------|------------|----------|
| small | 10Gi | 8Gi | Development |
| medium | 50Gi | 20Gi (HA) | Production |
| large | 100Gi+ | 50Gi+ | Enterprise |

```bash
./bootstrap.sh --nodes=N --tier=SIZE
```

---

## Security Model

### Credential Flow

1. **Phase 1**: Generated in-memory, never on disk
2. **Phase 2**: Used for state migration, then cleared
3. **Phase 3+**: Vault manages all secrets (via Flux)

### Zero-Secrets Architecture

- Git repositories: No secrets ever
- Bootstrap: In-memory only
- Runtime: Vault + External Secrets

---

## Troubleshooting

### General

```bash
LOG_LEVEL=TRACE    # Use TRACE logging
--force            # Force cleanup
--skip-phase0      # Faster iteration
```

### Phase 1 Issues

```bash
kubectl get pods -n bootstrap
kubectl logs -n bootstrap -l app=minio
ls -la /tmp/bootstrap-state
```

### Phase 2 Issues

```bash
flux get sources git
flux get kustomizations -A
kubectl logs -n flux-system -l app=source-controller
```

### Recovery

```bash
# Full cleanup and restart
curl -sfL .../scripts/cleanup.sh | bash -s -- --force
curl -sfL .../bootstrap.sh | GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small
```

---

## Additional Documentation

- [ARCHITECTURE.md](../ARCHITECTURE.md) - TO-BE architecture
- [MIGRATION.md](../MIGRATION.md) - Progress tracking
- [CLAUDE.md](../CLAUDE.md) - Operational procedures
