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
    # In MinIO, access_key IS the username (we use the friendly name as access_key)
    access_key="${username}"
    secret_key=$(openssl rand -hex 32)

    log_debug "[MinIO] access_key (username): ${access_key}, secret_key length: ${#secret_key}"

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

    # Create user (mc admin user add ALIAS ACCESSKEY SECRETKEY)
    # In MinIO, the access_key IS the username
    log_debug "[MinIO] Creating user with access_key='$access_key'"
    if ! mc admin user add minio "${access_key}" "${secret_key}" 1>&2; then
        log_error "[MinIO] Failed to create user '$access_key'"
        return 1
    fi

    # Attach policy to user (reference by access_key which is the username)
    log_debug "[MinIO] Attaching policy to user '$access_key'"
    if ! mc admin policy attach minio "${username}-policy" --user "$access_key" 1>&2; then
        log_error "[MinIO] Failed to attach policy to user '$access_key'"
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
