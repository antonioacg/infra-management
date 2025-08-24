# 2-Minute Quickstart

**For experienced users**: Deploy complete zero-secrets GitOps infrastructure in ~5 minutes.

## Prerequisites Checklist

**Hardware:**
- [ ] Fresh Ubuntu 20.04+ server or Raspberry Pi 4 (4GB+ RAM)
- [ ] 32GB+ storage, internet access, sudo privileges

**Credentials:**  
- [ ] GitHub personal access token (`ghp_...`) with repo read/write access
- [ ] Cloudflare tunnel token from Zero Trust dashboard

**Auto-installed tools:** kubectl, flux, terraform (1.6.6+), vault CLI, jq, git, curl

## Single Command Deployment

```bash
# Set environment variables (cleared automatically after deployment)
export GITHUB_TOKEN="ghp_your_github_personal_access_token"
export CLOUDFLARE_TUNNEL_TOKEN="your_cloudflare_tunnel_token"

# Deploy complete 5-phase bootstrap
curl -sSL https://raw.githubusercontent.com/antonioacg/infra-management/main/bootstrap.sh | bash
```

## What Happens (5 Phases)

1. **Infrastructure** (2min): k3s + Flux + Vault + External Secrets
2. **Secrets** (1min): ALL secrets → Vault via Terraform, env vars cleared
3. **Handoff** (1min): Flux switches from bootstrap token to External Secrets
4. **Apps** (1min): Applications deploy with External Secrets working
5. **Verify** (30s): Zero-secrets achieved, platform self-contained

## Success Indicators

```bash
# All pods running
kubectl get pods -A

# GitOps working
flux get all --all-namespaces

# External Secrets syncing  
kubectl get externalsecrets -A

# Zero-secrets achieved
kubectl get gitrepository flux-system -n flux-system -o jsonpath='{.spec.secretRef.name}'
# Should show: flux-system (not empty - means using External Secrets)
```

## Next Steps

- **Monitor**: `kubectl get pods -A -w`
- **Access services**: Via your Cloudflare tunnel  
- **Add secrets**: Use Terraform with self-referencing patterns
- **Troubleshooting**: See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

## Architecture Deep Dive

See [ARCHITECTURE.md](ARCHITECTURE.md) for complete 5-phase explanation and security model.

---

**Result**: True zero-secrets GitOps platform - no secrets in Git, environment variables cleared, all secrets managed through Vault → External Secrets → Kubernetes.