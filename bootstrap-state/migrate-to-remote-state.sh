#!/bin/bash
# Migrate Terraform state from local to remote MinIO backend
# This script handles the complete migration process safely

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/.minio-credentials"

echo "=== Terraform State Migration to Remote Backend ==="
echo ""

# Check prerequisites
if [[ ! -f "$CREDS_FILE" ]]; then
    echo "❌ ERROR: Credentials file not found: $CREDS_FILE"
    echo "Run ./generate-credentials.sh first"
    exit 1
fi

if [[ ! -f "terraform.tfstate" ]]; then
    echo "❌ ERROR: Local state file not found: terraform.tfstate"
    echo "Initialize Terraform first with: terraform init && terraform apply"
    exit 1
fi

# Source credentials
source "$CREDS_FILE"

echo "📋 Migration Plan:"
echo "  From: Local state file (terraform.tfstate)"
echo "  To:   MinIO S3 backend (bootstrap-minio.bootstrap.svc.cluster.local:9000)"
echo "  Bucket: terraform-state"
echo "  Key: bootstrap/terraform.tfstate"
echo ""

# Check if MinIO is accessible
echo "🔍 Checking MinIO accessibility..."
if kubectl get svc -n bootstrap bootstrap-minio &>/dev/null; then
    echo "✅ MinIO service found"
else
    echo "❌ ERROR: MinIO service not found in bootstrap namespace"
    echo "Deploy MinIO infrastructure first"
    exit 1
fi

# Create backup of current state
echo "💾 Creating backup of current state..."
cp terraform.tfstate "terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)"
echo "✅ Backup created"

# Port forward to MinIO for migration
echo "🌐 Setting up port forward to MinIO..."
kubectl port-forward -n bootstrap svc/bootstrap-minio 9000:9000 &>/dev/null &
PF_PID=$!
sleep 3

# Function to cleanup port forward
cleanup() {
    if [[ -n "${PF_PID:-}" ]]; then
        kill $PF_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Test connectivity
echo "🔌 Testing MinIO connectivity..."
if curl -s "http://localhost:9000/minio/health/ready" &>/dev/null; then
    echo "✅ MinIO is accessible"
else
    echo "❌ ERROR: Cannot connect to MinIO"
    echo "Check MinIO deployment and try again"
    exit 1
fi

# Check if bucket exists, create if not
echo "🪣 Checking terraform-state bucket..."
# We'll let Terraform handle bucket creation during init

# Perform state migration
echo "🚀 Performing state migration..."
echo "This will:"
echo "  1. Reconfigure Terraform backend to use MinIO"
echo "  2. Migrate existing state to remote backend"
echo "  3. Verify migration was successful"
echo ""

read -p "Continue with migration? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Migration cancelled"
    exit 0
fi

# Initialize with remote backend and migrate state
echo "📤 Migrating state to remote backend..."
terraform init -migrate-state -backend-config=backend-remote.hcl

# Verify migration
echo "✅ Verifying migration..."
if terraform state list &>/dev/null; then
    echo "✅ State migration successful!"
    echo "✅ Remote backend is working"
else
    echo "❌ ERROR: State migration verification failed"
    exit 1
fi

# Show final status
echo ""
echo "🎉 State migration completed successfully!"
echo ""
echo "📍 Current configuration:"
echo "  Backend: S3 (MinIO)"
echo "  Endpoint: bootstrap-minio.bootstrap.svc.cluster.local:9000"
echo "  Bucket: terraform-state"
echo "  Key: bootstrap/terraform.tfstate"
echo ""
echo "🔄 Next steps:"
echo "  - All future terraform operations will use remote state"
echo "  - You can run terraform plan/apply normally"
echo "  - State is now shared and locked via PostgreSQL"
echo ""
echo "⚠️  Important:"
echo "  - Keep your .minio-credentials file secure"
echo "  - The local terraform.tfstate file is now obsolete"
echo "  - Backups are stored as terraform.tfstate.backup.*"