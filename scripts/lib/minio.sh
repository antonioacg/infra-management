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

# Wait for Vault to be ready for credential storage
# Returns 0 if ready, 1 if timeout
_wait_for_vault() {
    local max_wait="${1:-300}"  # 5 minutes default
    local interval=10
    local elapsed=0

    log_info "[Phase 2d] Waiting for Vault to be ready (timeout: ${max_wait}s)..."

    while [[ $elapsed -lt $max_wait ]]; do
        local vault_pod vault_token

        vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [[ -n "$vault_pod" ]]; then
            # Check if pod is running
            local phase
            phase=$(kubectl get pod -n vault "$vault_pod" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

            if [[ "$phase" == "Running" ]]; then
                # Check if Vault is unsealed (root token available)
                vault_token=$(kubectl get secret vault-unseal-keys -n vault \
                    -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || echo "")

                if [[ -n "$vault_token" ]]; then
                    # Verify Vault is actually responding
                    if kubectl exec -n vault "$vault_pod" -- env \
                        VAULT_TOKEN="$vault_token" \
                        VAULT_SKIP_VERIFY=true \
                        vault status &>/dev/null; then
                        log_success "[Phase 2d] Vault is ready"
                        return 0
                    fi
                fi
            fi
        fi

        log_debug "[Phase 2d] Vault not ready, waiting ${interval}s... (${elapsed}s/${max_wait}s)"
        sleep $interval
        ((elapsed += interval))
    done

    log_error "[Phase 2d] Timeout waiting for Vault after ${max_wait}s"
    return 1
}

# Store MinIO credentials in Vault (after Vault is ready)
# Stores: tf-user creds (for tf-controller) and root creds (for admin/rotation)
# CRITICAL: Returns non-zero on failure - credentials will be lost if not stored!
_store_minio_creds_in_vault() {
    log_info "[Phase 2d] Storing MinIO credentials in Vault..."

    # Wait for Vault to be ready (critical for credential persistence)
    if ! _wait_for_vault 300; then
        log_error "[Phase 2d] Cannot store MinIO credentials - Vault not available"
        log_error "[Phase 2d] CRITICAL: tf-user credentials will be lost!"
        return 1
    fi

    local vault_pod vault_token

    vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    vault_token=$(kubectl get secret vault-unseal-keys -n vault \
        -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)

    # Store tf-user credentials (for tf-controller) with retry
    if [[ -n "${TF_MINIO_ACCESS_KEY:-}" && -n "${TF_MINIO_SECRET_KEY:-}" ]]; then
        local max_attempts=3
        local attempt=1
        local stored=false

        while [[ $attempt -le $max_attempts && "$stored" == "false" ]]; do
            if kubectl exec -n vault "$vault_pod" -- env \
                VAULT_TOKEN="$vault_token" \
                VAULT_SKIP_VERIFY=true \
                vault kv put secret/infra/minio/tf-user \
                access_key="$TF_MINIO_ACCESS_KEY" \
                secret_key="$TF_MINIO_SECRET_KEY" &>/dev/null; then
                log_success "[Phase 2d] tf-user credentials stored in Vault"
                stored=true
            else
                log_warning "[Phase 2d] tf-user storage attempt $attempt/$max_attempts failed"
                ((attempt++))
                [[ $attempt -le $max_attempts ]] && sleep 5
            fi
        done

        if [[ "$stored" == "false" ]]; then
            log_error "[Phase 2d] Failed to store tf-user credentials after $max_attempts attempts"
            return 1
        fi
    else
        log_error "[Phase 2d] tf-user credentials not found in environment"
        return 1
    fi

    # Store root credentials (for admin/rotation) - non-fatal if this fails
    if [[ -n "${MINIO_ROOT_USER:-}" && -n "${MINIO_ROOT_PASSWORD:-}" ]]; then
        if kubectl exec -n vault "$vault_pod" -- env \
            VAULT_TOKEN="$vault_token" \
            VAULT_SKIP_VERIFY=true \
            vault kv put secret/infra/minio/root \
            root_user="$MINIO_ROOT_USER" \
            root_password="$MINIO_ROOT_PASSWORD" &>/dev/null; then
            log_success "[Phase 2d] MinIO root credentials stored in Vault"
        else
            log_warning "[Phase 2d] Failed to store MinIO root credentials"
        fi
    fi
}

# Store PostgreSQL credentials in Vault (after Vault is ready)
# Stores: terraform user creds (least privilege for terraform_locks DB)
# CRITICAL: Returns non-zero on failure - credentials will be lost if not stored!
# Note: Called after _store_minio_creds_in_vault, so Vault wait already done
_store_postgres_creds_in_vault() {
    log_info "[Phase 2d] Storing PostgreSQL credentials in Vault..."

    local vault_pod vault_token

    vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    vault_token=$(kubectl get secret vault-unseal-keys -n vault \
        -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)

    # Verify Vault is still accessible (should be after MinIO creds were stored)
    if [[ -z "$vault_pod" || -z "$vault_token" ]]; then
        log_error "[Phase 2d] Vault not accessible for PostgreSQL credential storage"
        return 1
    fi

    # Store terraform user credentials (for state locking) with retry
    if [[ -n "${TF_VAR_postgres_terraform_password:-}" ]]; then
        local max_attempts=3
        local attempt=1
        local stored=false

        while [[ $attempt -le $max_attempts && "$stored" == "false" ]]; do
            if kubectl exec -n vault "$vault_pod" -- env \
                VAULT_TOKEN="$vault_token" \
                VAULT_SKIP_VERIFY=true \
                vault kv put secret/infra/postgresql/terraform-user \
                username="terraform" \
                password="$TF_VAR_postgres_terraform_password" &>/dev/null; then
                log_success "[Phase 2d] PostgreSQL terraform-user credentials stored in Vault"
                stored=true
            else
                log_warning "[Phase 2d] PostgreSQL terraform-user storage attempt $attempt/$max_attempts failed"
                ((attempt++))
                [[ $attempt -le $max_attempts ]] && sleep 5
            fi
        done

        if [[ "$stored" == "false" ]]; then
            log_error "[Phase 2d] Failed to store PostgreSQL terraform-user credentials after $max_attempts attempts"
            return 1
        fi
    else
        log_error "[Phase 2d] PostgreSQL terraform-user password not found in environment"
        return 1
    fi

    # Store superuser credentials (for admin/rotation) - non-fatal if this fails
    if [[ -n "${TF_VAR_postgres_password:-}" ]]; then
        if kubectl exec -n vault "$vault_pod" -- env \
            VAULT_TOKEN="$vault_token" \
            VAULT_SKIP_VERIFY=true \
            vault kv put secret/infra/postgresql/superuser \
            username="postgres" \
            password="$TF_VAR_postgres_password" &>/dev/null; then
            log_success "[Phase 2d] PostgreSQL superuser credentials stored in Vault"
        else
            log_warning "[Phase 2d] Failed to store PostgreSQL superuser credentials"
        fi
    fi
}
