#!/bin/bash
# Generate random MinIO credentials for bootstrap
# Proper flow: Script → Terraform → Vault (no K8s secrets for bootstrap creds)

set -euo pipefail

CREDS_FILE="${1:-$PWD/.minio-credentials}"

echo "Generating random MinIO credentials for bootstrap..."

# Generate random, secure credentials
MINIO_USER="admin-$(openssl rand -hex 4)"
MINIO_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | head -c 24)"

echo "Generated credentials:"
echo "  User: $MINIO_USER"
echo "  Password: [REDACTED]"

# Store credentials in temporary file for bootstrap phases
cat > "$CREDS_FILE" << EOF
export MINIO_ROOT_USER="$MINIO_USER"
export MINIO_ROOT_PASSWORD="$MINIO_PASSWORD"
export TF_VAR_minio_access_key="$MINIO_USER"
export TF_VAR_minio_secret_key="$MINIO_PASSWORD"
EOF

chmod 600 "$CREDS_FILE"

echo "Credentials stored in: $CREDS_FILE"
echo "Source this file in bootstrap scripts: source $CREDS_FILE"

# Create terraform.tfvars for backend configuration
BACKEND_VARS="terraform-backend.auto.tfvars"
cat > "$BACKEND_VARS" << EOF
# Auto-generated MinIO credentials for Terraform backend
# This file is temporary and will be replaced by Vault integration

minio_access_key = "$MINIO_USER"
minio_secret_key = "$MINIO_PASSWORD"
EOF

chmod 600 "$BACKEND_VARS"

# Create backend configuration file (local development)
BACKEND_CONFIG="backend.hcl"
cat > "$BACKEND_CONFIG" << EOF
# Terraform Backend Configuration
# Auto-generated with MinIO credentials

bucket                      = "terraform-state"
key                        = "bootstrap/terraform.tfstate"
region                     = "us-east-1"
endpoint                   = "http://localhost:9000"
access_key                 = "$MINIO_USER"
secret_key                 = "$MINIO_PASSWORD"
force_path_style          = true
skip_credentials_validation = true
skip_metadata_api_check    = true
skip_region_validation     = true
EOF

chmod 600 "$BACKEND_CONFIG"

# Create remote backend configuration file (production migration)
BACKEND_REMOTE_CONFIG="backend-remote.hcl"
cat > "$BACKEND_REMOTE_CONFIG" << EOF
# Remote Backend Configuration for State Migration
# Auto-generated with MinIO credentials

bucket                      = "terraform-state"
key                        = "bootstrap/terraform.tfstate"
region                     = "us-east-1"
endpoint                   = "http://bootstrap-minio.bootstrap.svc.cluster.local:9000"
access_key                 = "$MINIO_USER"
secret_key                 = "$MINIO_PASSWORD"
force_path_style          = true
skip_credentials_validation = true
skip_metadata_api_check    = true
skip_region_validation     = true
EOF

chmod 600 "$BACKEND_REMOTE_CONFIG"

echo "Backend variables stored in: $BACKEND_VARS"
echo "Backend configuration stored in: $BACKEND_CONFIG"
echo "Remote backend configuration stored in: $BACKEND_REMOTE_CONFIG"
echo ""
echo "Next steps:"
echo "1. Source credentials: source $CREDS_FILE"
echo "2. Deploy MinIO with these credentials"
echo "3. Configure Terraform backend"
echo "4. Store credentials in Vault during infrastructure phase"

echo "Bootstrap credentials generated successfully!"