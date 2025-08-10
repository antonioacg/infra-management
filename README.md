# Infra Management

Ultra-simple bootstrap orchestrator for zero-secrets Kubernetes infrastructure.

## Quick Start

Deploy a complete zero-secrets Kubernetes cluster from any fresh Ubuntu machine:

```bash
curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | \
  bash -s \
  "YOUR_GITHUB_TOKEN" \
  "YOUR_SOPS_AGE_KEY" \
  "YOUR_CLOUDFLARE_TUNNEL_TOKEN"
```

## What This Does

1. **Installs k3s** - Lightweight Kubernetes cluster
2. **Deploys GitOps stack** - Flux for continuous deployment from Git
3. **Initializes Vault** - Centralized secret management with auto-unseal
4. **Configures External Secrets** - Automatic secret sync from Vault to Kubernetes
5. **Populates initial secrets** - Via Terraform for declarative management

## Architecture

This bootstrap script orchestrates three repositories:

- **[deployments](https://github.com/antonioacg/deployments)** - Kubernetes manifests and Flux GitOps
- **[infra](https://github.com/antonioacg/infra)** - Terraform infrastructure and Vault configuration  
- **[infra-management](https://github.com/antonioacg/infra-management)** - This bootstrap orchestrator

## Prerequisites

- Fresh Ubuntu 20.04+ server with internet access
- SSH access to the server
- GitHub token with repository access
- SOPS Age key for secret encryption
- Cloudflare tunnel token

## Result

After ~5 minutes, you'll have:
- ✅ Zero secrets stored in Git repositories
- ✅ Centralized secret management via Vault
- ✅ Automatic secret synchronization to Kubernetes
- ✅ GitOps deployment pipeline with Flux
- ✅ Secure tunnel access via Cloudflare

## Documentation

- [Bootstrap Plan](docs/BOOTSTRAP_PLAN.md) - Comprehensive implementation details
- [Architecture](docs/ARCHITECTURE.md) - System design and component overview  
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Verification

Check your deployment:

```bash
# Verify all components are running
kubectl get pods -A

# Check GitOps status  
flux get all --all-namespaces

# Verify External Secrets synchronization
kubectl get externalsecrets -A

# Test Vault connectivity
kubectl exec -n vault vault-0 -- vault status
```

## Support

For issues or questions:
- Check [Troubleshooting Guide](docs/TROUBLESHOOTING.md)
- Review component logs: `kubectl logs -n <namespace> <pod-name>`
- Verify prerequisites and retry bootstrap

## Security

This bootstrap approach ensures:
- No secrets committed to Git repositories
- Encrypted secrets in transit and at rest
- Minimal credential exposure during bootstrap
- Automatic cleanup of temporary files