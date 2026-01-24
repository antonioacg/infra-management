# Bootstrap Orchestrator

**Flux-first GitOps platform** - single command bootstrap for scalable Kubernetes infrastructure.

## Quick Start

```bash
curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \
  GITHUB_TOKEN="ghp_xxx" bash -s -- --nodes=1 --tier=small
```

**Current Status**: All phases complete. GitOps operational.

## Bootstrap Phases

See [BOOTSTRAP.md](BOOTSTRAP.md) for complete details.

- **Phase 0**: Environment & tools validation
- **Phase 1**: k3s + MinIO + PostgreSQL (LOCAL state)
- **Phase 2**: State migration + Flux install (REMOTE state) → GitOps takes over

## Platform Repositories

- **infra-management** (this repo): Bootstrap scripts
- **[infra](https://github.com/antonioacg/infra)**: Bootstrap Terraform
- **[deployments](https://github.com/antonioacg/deployments)**: GitOps manifests (Flux source)

## Prerequisites

**Hardware:**
- Linux machine (ARM64 or x86_64)
- 4GB+ RAM, 20GB+ storage

**Credentials:**
- GitHub personal access token with `repo` scope

All tools installed automatically during Phase 0.

## After Bootstrap

**Phase 1 provides:**
- k3s cluster with data-at-rest encryption
- MinIO S3 storage + PostgreSQL (Terraform state backend)
- Credentials generated in-memory only

**Phase 2 adds:**
- Flux GitOps controllers
- State migrated to MinIO

**Post-bootstrap (via GitOps):**
- Vault, External Secrets, ingress, monitoring, apps

## Verification

```bash
kubectl get nodes
kubectl get pods -n bootstrap
kubectl get pvc -n bootstrap
```

## Documentation

- [BOOTSTRAP.md](BOOTSTRAP.md) - Phase definitions and usage
- [../ARCHITECTURE.md](../ARCHITECTURE.md) - Platform architecture
- [../CLAUDE.md](../CLAUDE.md) - Operational procedures
