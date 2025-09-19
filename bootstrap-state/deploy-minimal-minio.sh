#!/bin/bash
# Deploy minimal MinIO pod with generated credentials
# This is Phase 0 of the bootstrap process

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/.minio-credentials"

echo "Deploying minimal MinIO with generated credentials..."

# Check if credentials exist, generate if not
if [[ ! -f "$CREDS_FILE" ]]; then
    echo "Credentials not found, generating..."
    "$SCRIPT_DIR/generate-credentials.sh" "$CREDS_FILE"
fi

# Source the credentials
source "$CREDS_FILE"

echo "Using credentials:"
echo "  User: $MINIO_ROOT_USER"
echo "  Password: [REDACTED]"

# Substitute environment variables in the manifest and apply
envsubst < "$SCRIPT_DIR/minimal-minio.yaml" | kubectl apply -f -

echo "Waiting for minimal MinIO to be ready..."
kubectl wait --for=condition=ready pod/minimal-minio -n bootstrap-temp --timeout=60s

echo "Minimal MinIO deployed successfully!"
echo "Access via: kubectl port-forward -n bootstrap-temp pod/minimal-minio 9000:9000"

# Test connection
echo "Testing MinIO connection..."
if kubectl port-forward -n bootstrap-temp pod/minimal-minio 9000:9000 &>/dev/null &
then
    PF_PID=$!
    sleep 3

    if curl -s "http://localhost:9000/minio/health/ready" &>/dev/null; then
        echo "✅ MinIO is healthy and ready!"
    else
        echo "⚠️  MinIO deployed but health check failed"
    fi

    kill $PF_PID 2>/dev/null || true
fi

echo ""
echo "Next step: Run Terraform to deploy proper MinIO infrastructure"
echo "  cd bootstrap-state && terraform init -backend-config=backend.hcl"