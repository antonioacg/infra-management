# System Architecture

## Overview

The zero-secrets architecture uses a 3-repository approach with centralized secret management and GitOps deployment patterns.

## Repository Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│ infra-management│    │   deployments    │    │      infra      │
│                 │    │                  │    │                 │
│ • Bootstrap     │───▶│ • Kubernetes     │    │ • Terraform     │
│ • Orchestration │    │   Manifests      │    │ • Vault Config  │
│ • Documentation │    │ • Flux GitOps    │    │ • Secret Mgmt   │
│ • Tool Scripts  │    │ • Ext. Secrets   │    │ • State Backend │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 ▼
                    ┌─────────────────────────┐
                    │   Kubernetes Cluster    │
                    │                         │
                    │ ┌─────┐ ┌─────────────┐ │
                    │ │Vault│ │External     │ │
                    │ │     │ │Secrets      │ │
                    │ └─────┘ │Operator     │ │
                    │         └─────────────┘ │
                    └─────────────────────────┘
```

## Component Flow

### Bootstrap Flow
1. **infra-management/bootstrap.sh** - Master orchestrator
2. **deployments/install.sh** - GitOps and Kubernetes setup  
3. **infra/terraform** - Infrastructure and secret population
4. **Verification** - Health checks and validation

### Secret Management Flow
```
Developer/CI → Terraform → Vault → External Secrets → K8s Secrets → Applications
```

### GitOps Flow
```
Git Repository → Flux → Kubernetes API → Applications
```

## Core Components

### Kubernetes Cluster (k3s)
- **Purpose**: Container orchestration platform
- **Configuration**: Single-node k3s with local storage
- **Management**: GitOps via Flux CD
- **Networking**: Nginx Ingress Controller

### Flux CD (GitOps)
- **Purpose**: Continuous deployment from Git
- **Source**: deployments repository  
- **Features**: SOPS decryption, automatic reconciliation
- **Monitoring**: Built-in metrics and logging

### HashiCorp Vault
- **Purpose**: Centralized secret storage and management
- **Authentication**: Kubernetes service account auth
- **Backend**: MinIO S3-compatible storage
- **Features**: Auto-unseal, audit logging, KV secrets engine

### External Secrets Operator
- **Purpose**: Automatic secret synchronization
- **Source**: Vault KV secrets engine
- **Target**: Kubernetes native secrets
- **Features**: Automatic rotation, error handling

### Cloudflared Tunnel  
- **Purpose**: Secure external access without port exposure
- **Configuration**: Cloudflare tunnel with nginx ingress
- **Security**: Zero-trust network access model

### MinIO
- **Purpose**: S3-compatible object storage
- **Usage**: Vault backend, Terraform state storage
- **Features**: High availability, encryption at rest

## Security Architecture

### Secret Flow Security
1. **Secrets never stored in Git** - Only references and templates
2. **Vault as single source of truth** - Centralized secret management
3. **Kubernetes auth** - Service account-based access
4. **Network isolation** - Cluster-internal communication
5. **Encryption at rest and in transit** - TLS everywhere

### Access Control
- **Vault Policies** - Fine-grained secret access control
- **Kubernetes RBAC** - Service account permissions
- **Network Policies** - Pod-to-pod communication control
- **Age Encryption** - Bootstrap secret protection

### Key Management
- **Age Keys** - SOPS encryption/decryption
- **Vault Unseal Keys** - Stored in Kubernetes secrets with RBAC
- **Root Tokens** - Automatically revoked after setup
- **Service Account Tokens** - Kubernetes-managed lifecycle

## Network Architecture

### External Traffic Flow
```
Internet → Cloudflare → Cloudflared → Nginx Ingress → Services
```

### Internal Communication
```
External Secrets ←→ Vault (HTTP/8200)
Terraform ←→ Vault (Port-forward/8200)
Flux ←→ Kubernetes API (HTTPS/6443)
Applications ←→ Kubernetes Services (ClusterIP)
```

## Data Flow

### Bootstrap Data
1. **GitHub Token** - Repository access (temporary)
2. **Age Key** - SOPS decryption (bootstrap only)  
3. **Tunnel Token** - Cloudflare access (stored in Vault)

### Runtime Data
1. **Kubernetes Secrets** - Auto-synced from Vault
2. **Vault Storage** - Persistent in MinIO
3. **Terraform State** - Stored in MinIO backend
4. **Application Data** - Container volumes and PVCs

## Scalability Considerations

### Horizontal Scaling
- **Multiple Environments** - Separate Terraform workspaces
- **Application Scaling** - Kubernetes HPA and VPA
- **Secret Distribution** - External Secrets Operator per namespace

### High Availability
- **Vault HA** - Multiple replicas with shared storage
- **k3s HA** - Multi-master configuration (future)
- **Storage HA** - MinIO distributed mode
- **Network HA** - Multiple Cloudflare tunnels

## Monitoring and Observability

### Metrics Collection
- **Kubernetes Metrics** - Built-in metrics server
- **Vault Metrics** - Telemetry endpoint
- **External Secrets Metrics** - Prometheus integration
- **Application Metrics** - Custom application metrics

### Logging
- **Kubernetes Logs** - kubectl logs integration
- **Vault Audit Logs** - File-based audit logging
- **Flux Logs** - GitOps operation logging
- **Application Logs** - Structured logging to stdout

### Health Checks
- **Kubernetes Probes** - Liveness and readiness checks
- **Vault Health** - Built-in health endpoint
- **External Secrets** - CRD status monitoring
- **Network Connectivity** - Ingress health checks

## Disaster Recovery

### Backup Strategy
- **Vault Data** - MinIO backup with versioning
- **Kubernetes Config** - GitOps source backup
- **Age Keys** - Secure offline storage
- **Terraform State** - MinIO versioning and replication

### Recovery Procedures
- **Complete Rebuild** - Bootstrap script re-execution
- **Partial Recovery** - Component-specific restoration
- **State Recovery** - Terraform import and reconciliation
- **Secret Recovery** - Vault unsealing and restoration

## Future Architecture Enhancements

### Multi-Cluster Support
- **Federated Secrets** - Cross-cluster secret sharing
- **Central Vault** - Shared secret management
- **GitOps Multi-tenancy** - Environment-specific deployments

### Advanced Secret Management
- **Dynamic Secrets** - Database and API credential rotation
- **Secret Rotation** - Automated credential lifecycle
- **Policy Automation** - Dynamic Vault policy management

### Enhanced Monitoring
- **Prometheus Stack** - Comprehensive metrics collection
- **Grafana Dashboards** - Visual monitoring and alerting
- **Log Aggregation** - Centralized log analysis
- **Tracing** - Distributed request tracing