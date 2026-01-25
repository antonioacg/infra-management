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

## User-Provided Secrets

Some secrets cannot be generated automatically and must be provided during bootstrap or added later.

### Bootstrap Time (Recommended)

Pass secrets as environment variables prefixed with `VAULT_INPUT_`:

```bash
GITHUB_TOKEN=xxx \
VAULT_INPUT_github_token=xxx \
VAULT_INPUT_cloudflare_token=yyy \
./bootstrap.sh
```

### Post-Bootstrap (GitHub Actions)

Use the "Add Secret to Vault" workflow in the `infra-management` repo:
1. Add secret to GitHub Repo Settings -> Secrets (e.g. `CLOUDFLARE_TOKEN`)
2. Run "Add Secret to Vault" workflow
3. Select secret name from list (e.g. `cloudflare_token`)

### Manual (Emergency)

```bash
kubectl port-forward -n vault svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
vault kv patch secret/bootstrap/inputs cloudflare_token=xxx
```

### Required Secrets

| Secret Name | Variable Name | Description | Source |
|-------------|---------------|-------------|--------|
| `github_token` | `VAULT_INPUT_github_token` | PAT for Renovate/Flux | GitHub Settings |
| `cloudflare_token` | `VAULT_INPUT_cloudflare_token` | API Token for Cloudflared | Cloudflare Dashboard |
| `datadog_api_key` | `VAULT_INPUT_datadog_api_key` | API Key for Datadog Agent | Datadog Dashboard |

## Platform Repositories

- **infra-management** (this repo): Bootstrap scripts
- **[infra](https://github.com/antonioacg/infra)**: Bootstrap Terraform
- **[deployments](https://github.com/antonioacg/deployments)**: GitOps manifests (Flux source)

## Prerequisites

**Hardware:**
- Linux machine (ARM64 or x86_64)
- 4GB+ RAM, 20GB+ storage

**Credentials:**
- GitHub personal access token with `repo` and `workflow` scopes

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
kubectl get pods -n storage      # MinIO pods
kubectl get pods -n databases    # PostgreSQL pods
kubectl get pvc -n storage
kubectl get pvc -n databases
```

## Documentation

- [BOOTSTRAP.md](BOOTSTRAP.md) - Phase definitions and usage
- [../ARCHITECTURE.md](../ARCHITECTURE.md) - Platform architecture
- [../CLAUDE.md](../CLAUDE.md) - Operational procedures
