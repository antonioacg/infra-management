#!/bin/bash
# MinIO user management library
# Creates least-privilege users with bucket-specific policies

# PRIVATE: Create MinIO user with bucket-specific policy
# Usage: _create_minio_user "username" "bucket_name"
# Returns: "access_key:secret_key"
_create_minio_user() {
    local username="$1"
    local bucket="$2"
    local access_key secret_key
    local policy_json

    log_info "[MinIO] Creating user '$username' with access to bucket '$bucket'..."

    # Generate credentials
    access_key=$(openssl rand -hex 16)
    secret_key=$(openssl rand -hex 32)

    log_debug "[MinIO] Generated access_key length: ${#access_key}, secret_key length: ${#secret_key}"

    # Create policy JSON
    policy_json=$(cat <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": ["s3:*"],
        "Resource": [
            "arn:aws:s3:::${bucket}",
            "arn:aws:s3:::${bucket}/*"
        ]
    }]
}
POLICY
)

    # Create policy for bucket access only
    log_debug "[MinIO] Creating policy '${username}-policy' for bucket '$bucket'"
    echo "$policy_json" | mc admin policy create minio "${username}-policy" /dev/stdin 1>&2 || {
        log_error "[MinIO] Failed to create policy"
        return 1
    }

    # Create user
    log_debug "[MinIO] Creating user '$username' with generated credentials"
    if ! mc admin user add minio "${username}" "${access_key}" "${secret_key}" 1>&2; then
        log_error "[MinIO] Failed to create user '$username'"
        return 1
    fi

    # Attach policy to user
    log_debug "[MinIO] Attaching policy to user '$username'"
    if ! mc admin policy attach minio "${username}-policy" --user "$username" 1>&2; then
        log_error "[MinIO] Failed to attach policy to user '$username'"
        return 1
    fi

    log_success "[MinIO] User '$username' created with bucket '$bucket' access"
    echo "${access_key}:${secret_key}"
}

# Create MinIO users for Vault and tf-controller with least privilege
# Requires: mc alias "minio" to be configured
_create_minio_users() {
    log_info "[Phase 2b] Creating MinIO users with least privilege..."

    # Setup mc alias using root credentials (TF_VAR_* set by credentials.sh)
    log_info "[MinIO] Configuring mc alias for MinIO..."
    local minio_user="${MINIO_ROOT_USER:-$TF_VAR_minio_root_user}"
    local minio_pass="${MINIO_ROOT_PASSWORD:-$TF_VAR_minio_root_password}"
    log_debug "[MinIO] Using MinIO user: ${minio_user:0:8}..."
    mc alias set minio "http://localhost:9000" "$minio_user" "$minio_pass" --quiet

    # Create vault-user (vault-storage bucket only)
    local vault_creds
    vault_creds=$(_create_minio_user "vault-user" "vault-storage")
    VAULT_MINIO_ACCESS_KEY="${vault_creds%%:*}"
    VAULT_MINIO_SECRET_KEY="${vault_creds##*:}"

    # Store Vault's MinIO creds in minio namespace (NOT in Vault - chicken-egg)
    log_info "[MinIO] Storing vault-minio-credentials in minio namespace..."
    kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic vault-minio-credentials \
        --namespace=minio \
        --from-literal=access_key="$VAULT_MINIO_ACCESS_KEY" \
        --from-literal=secret_key="$VAULT_MINIO_SECRET_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_success "[MinIO] vault-minio-credentials stored in minio namespace"

    # Create tf-user (terraform-state bucket only)
    local tf_creds
    tf_creds=$(_create_minio_user "tf-user" "terraform-state")
    TF_MINIO_ACCESS_KEY="${tf_creds%%:*}"
    TF_MINIO_SECRET_KEY="${tf_creds##*:}"

    # Export for later storage in Vault
    export TF_MINIO_ACCESS_KEY TF_MINIO_SECRET_KEY
    export VAULT_MINIO_ACCESS_KEY VAULT_MINIO_SECRET_KEY

    log_success "[Phase 2b] MinIO users created with least privilege"
}

# Store MinIO credentials in Vault (after Vault is ready)
# Stores: tf-user creds (for tf-controller) and root creds (for admin/rotation)
_store_minio_creds_in_vault() {
    log_info "[Phase 2d] Storing MinIO credentials in Vault..."

    local vault_pod vault_token

    vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$vault_pod" ]]; then
        log_warning "[Phase 2d] Vault pod not found, skipping MinIO credential storage"
        return 0
    fi

    vault_token=$(kubectl get secret vault-unseal-keys -n vault \
        -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "$vault_token" ]]; then
        log_warning "[Phase 2d] Vault root token not found, skipping MinIO credential storage"
        return 0
    fi

    # Store tf-user credentials (for tf-controller)
    if [[ -n "${TF_MINIO_ACCESS_KEY:-}" && -n "${TF_MINIO_SECRET_KEY:-}" ]]; then
        if kubectl exec -n vault "$vault_pod" -- env \
            VAULT_TOKEN="$vault_token" \
            VAULT_SKIP_VERIFY=true \
            vault kv put secret/infra/minio/tf-user \
            access_key="$TF_MINIO_ACCESS_KEY" \
            secret_key="$TF_MINIO_SECRET_KEY" &>/dev/null; then
            log_success "[Phase 2d] tf-user credentials stored in Vault"
        else
            log_warning "[Phase 2d] Failed to store tf-user credentials in Vault"
        fi
    fi

    # Store root credentials (for admin/rotation)
    if [[ -n "${MINIO_ROOT_USER:-}" && -n "${MINIO_ROOT_PASSWORD:-}" ]]; then
        if kubectl exec -n vault "$vault_pod" -- env \
            VAULT_TOKEN="$vault_token" \
            VAULT_SKIP_VERIFY=true \
            vault kv put secret/infra/minio/root \
            root_user="$MINIO_ROOT_USER" \
            root_password="$MINIO_ROOT_PASSWORD" &>/dev/null; then
            log_success "[Phase 2d] MinIO root credentials stored in Vault"
        else
            log_warning "[Phase 2d] Failed to store MinIO root credentials in Vault"
        fi
    fi
}
