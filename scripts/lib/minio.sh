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
# Checks: pod running, Vault unsealed, Kubernetes auth configured
# Returns 0 if ready, 1 if timeout
_wait_for_vault() {
    local max_wait="${1:-300}"  # 5 minutes default
    local interval=10
    local elapsed=0

    log_info "[Phase 2d] Waiting for Vault to be ready (timeout: ${max_wait}s)..."

    while [[ $elapsed -lt $max_wait ]]; do
        local vault_pod

        vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [[ -n "$vault_pod" ]]; then
            # Check if pod is running and ready
            local ready
            ready=$(kubectl get pod -n vault "$vault_pod" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

            if [[ "$ready" == "True" ]]; then
                # Check Vault is unsealed (status doesn't require auth)
                if kubectl exec -n vault "$vault_pod" -- env \
                    VAULT_SKIP_VERIFY=true \
                    vault status &>/dev/null; then
                    # Also check that vault-configurer has finished configuring auth
                    # This is critical - vault-configurer runs async and we need auth ready
                    # Check vault-configurer logs for success message
                    local configurer_pod
                    configurer_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault-configurator \
                        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                    if [[ -n "$configurer_pod" ]]; then
                        if kubectl logs -n vault "$configurer_pod" 2>/dev/null | grep -q "successfully configured vault"; then
                            log_success "[Phase 2d] Vault is ready and unsealed"
                            # Small delay to ensure all config is applied
                            sleep 5
                            return 0
                        else
                            log_debug "[Phase 2d] Vault unsealed but vault-configurer not finished yet"
                        fi
                    else
                        log_debug "[Phase 2d] Vault unsealed but vault-configurer pod not found"
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

# Write a secret to Vault using Kubernetes auth (vault-secret-writer SA)
# Usage: _vault_kv_put "secret/path" "key1=value1" "key2=value2" ...
# Returns 0 on success, 1 on failure
_vault_kv_put() {
    local secret_path="$1"
    shift
    local kv_pairs="$*"

    local pod_name="vault-writer-$(date +%s)"
    local vault_addr="https://vault.vault.svc:8200"

    log_debug "[Vault] Writing to ${secret_path} using Kubernetes auth..."

    # Run a one-shot pod with vault-secret-writer SA to write the secret
    # The pod authenticates via Kubernetes auth, writes the secret, then exits
    # Note: Using --overrides to set serviceAccountName (--serviceaccount not available in all kubectl versions)
    if kubectl run "$pod_name" \
        --namespace=vault-jobs \
        --overrides='{"spec":{"serviceAccountName":"vault-secret-writer"}}' \
        --image=hashicorp/vault:1.15 \
        --restart=Never \
        --rm \
        --attach \
        --quiet \
        --command -- /bin/sh -c "
            export VAULT_ADDR='${vault_addr}'
            export VAULT_SKIP_VERIFY=true

            # Authenticate using Kubernetes auth
            TOKEN=\$(vault write -field=token auth/kubernetes/login \
                role=secret-writer \
                jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))

            if [ -z \"\$TOKEN\" ]; then
                echo 'Failed to authenticate to Vault' >&2
                exit 1
            fi

            export VAULT_TOKEN=\$TOKEN

            # Write the secret
            vault kv put ${secret_path} ${kv_pairs}
        " 2>/dev/null; then
        return 0
    else
        # Clean up pod if it failed and wasn't removed
        kubectl delete pod "$pod_name" -n vault-jobs --ignore-not-found=true &>/dev/null
        return 1
    fi
}

# Store MinIO credentials in Vault (after Vault is ready)
# Uses Kubernetes auth via vault-secret-writer service account
# CRITICAL: Returns non-zero on failure - credentials will be lost if not stored!
_store_minio_creds_in_vault() {
    log_info "[Phase 2d] Storing MinIO credentials in Vault..."

    # Wait for Vault to be ready (critical for credential persistence)
    if ! _wait_for_vault 300; then
        log_error "[Phase 2d] Cannot store MinIO credentials - Vault not available"
        log_error "[Phase 2d] CRITICAL: tf-user credentials will be lost!"
        return 1
    fi

    # Store tf-user credentials (for tf-controller) with retry
    if [[ -n "${TF_MINIO_ACCESS_KEY:-}" && -n "${TF_MINIO_SECRET_KEY:-}" ]]; then
        local max_attempts=3
        local attempt=1
        local stored=false

        while [[ $attempt -le $max_attempts && "$stored" == "false" ]]; do
            if _vault_kv_put "secret/infra/minio/tf-user" \
                "access_key=${TF_MINIO_ACCESS_KEY}" \
                "secret_key=${TF_MINIO_SECRET_KEY}"; then
                log_success "[Phase 2d] MinIO tf-user credentials stored in Vault"
                stored=true
            else
                log_warning "[Phase 2d] MinIO tf-user storage attempt $attempt/$max_attempts failed"
                ((attempt++))
                [[ $attempt -le $max_attempts ]] && sleep 5
            fi
        done

        if [[ "$stored" == "false" ]]; then
            log_error "[Phase 2d] Failed to store MinIO tf-user credentials after $max_attempts attempts"
            return 1
        fi
    else
        log_error "[Phase 2d] MinIO tf-user credentials not found in environment"
        return 1
    fi

    # Store root credentials (for admin/rotation) - non-fatal if this fails
    if [[ -n "${MINIO_ROOT_USER:-}" && -n "${MINIO_ROOT_PASSWORD:-}" ]]; then
        if _vault_kv_put "secret/infra/minio/root" \
            "root_user=${MINIO_ROOT_USER}" \
            "root_password=${MINIO_ROOT_PASSWORD}"; then
            log_success "[Phase 2d] MinIO root credentials stored in Vault"
        else
            log_warning "[Phase 2d] Failed to store MinIO root credentials"
        fi
    fi
}

# Store PostgreSQL credentials in Vault (after Vault is ready)
# Uses Kubernetes auth via vault-secret-writer service account
# CRITICAL: Returns non-zero on failure - credentials will be lost if not stored!
# Note: Called after _store_minio_creds_in_vault, so Vault wait already done
_store_postgres_creds_in_vault() {
    log_info "[Phase 2d] Storing PostgreSQL credentials in Vault..."

    # Store tf-user credentials (for state locking) with retry
    if [[ -n "${TF_VAR_postgres_tf_password:-}" ]]; then
        local max_attempts=3
        local attempt=1
        local stored=false

        while [[ $attempt -le $max_attempts && "$stored" == "false" ]]; do
            if _vault_kv_put "secret/infra/postgresql/tf-user" \
                "username=tf-user" \
                "password=${TF_VAR_postgres_tf_password}"; then
                log_success "[Phase 2d] PostgreSQL tf-user credentials stored in Vault"
                stored=true
            else
                log_warning "[Phase 2d] PostgreSQL tf-user storage attempt $attempt/$max_attempts failed"
                ((attempt++))
                [[ $attempt -le $max_attempts ]] && sleep 5
            fi
        done

        if [[ "$stored" == "false" ]]; then
            log_error "[Phase 2d] Failed to store PostgreSQL tf-user credentials after $max_attempts attempts"
            return 1
        fi
    else
        log_error "[Phase 2d] PostgreSQL tf-user password not found in environment (TF_VAR_postgres_tf_password)"
        return 1
    fi

    # Store superuser credentials (for admin/rotation) - non-fatal if this fails
    if [[ -n "${TF_VAR_postgres_password:-}" ]]; then
        if _vault_kv_put "secret/infra/postgresql/superuser" \
            "username=postgres" \
            "password=${TF_VAR_postgres_password}"; then
            log_success "[Phase 2d] PostgreSQL superuser credentials stored in Vault"
        else
            log_warning "[Phase 2d] Failed to store PostgreSQL superuser credentials"
        fi
    fi
}
