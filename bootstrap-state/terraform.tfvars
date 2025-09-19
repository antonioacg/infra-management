# Bootstrap State Environment Configuration
# This file defines the environment-specific variables for scaling

# Environment: homelab (1-2 nodes) or business (3+ nodes)
environment = "homelab"

# Node configuration
node_count = 1

# Storage configuration for homelab environment
minio_storage_size = "10Gi"
postgresql_storage_size = "8Gi"