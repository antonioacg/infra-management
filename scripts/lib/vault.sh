#!/bin/bash
# Vault interaction library
# Readiness checks, persistent writer pod, and secret writes

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

# Vault writer pod management
# Uses a single persistent pod for all credential writes to avoid
# NetworkPolicy ipset race conditions with ephemeral pods
VAULT_WRITER_POD="vault-writer-persistent"
VAULT_WRITER_READY=false

# Start a persistent Vault writer pod in vault-jobs namespace
# The pod authenticates once and stays alive for multiple writes
_start_vault_writer() {
    local vault_addr="https://vault.vault.svc:8200"

    log_debug "[Vault] Starting persistent writer pod..."

    # Clean up any leftover pod from a previous run
    kubectl delete pod "$VAULT_WRITER_POD" -n vault-jobs --ignore-not-found=true &>/dev/null

    # Create a long-running pod that sleeps, waiting for exec commands
    kubectl run "$VAULT_WRITER_POD" \
        --namespace=vault-jobs \
        --overrides='{"spec":{"serviceAccountName":"vault-secret-writer"}}' \
        --image=hashicorp/vault:1.15 \
        --restart=Never \
        --command -- /bin/sh -c "sleep 600" &>/dev/null

    # Wait for the pod to be ready
    if ! kubectl wait --for=condition=Ready pod/"$VAULT_WRITER_POD" -n vault-jobs --timeout=60s &>/dev/null; then
        log_error "[Vault] Writer pod failed to start"
        kubectl delete pod "$VAULT_WRITER_POD" -n vault-jobs --ignore-not-found=true &>/dev/null
        return 1
    fi

    # Wait for NetworkPolicy ipsets to include the new pod
    sleep 3

    # Authenticate and store token in a file inside the pod
    if ! kubectl exec "$VAULT_WRITER_POD" -n vault-jobs -- /bin/sh -c "
        export VAULT_ADDR='${vault_addr}'
        export VAULT_SKIP_VERIFY=true
        TOKEN=\$(vault write -field=token auth/kubernetes/login \
            role=secret-writer \
            jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
        if [ -z \"\$TOKEN\" ]; then
            echo 'Failed to authenticate to Vault' >&2
            exit 1
        fi
        echo \"\$TOKEN\" > /tmp/vault-token
    " 2>/dev/null; then
        log_error "[Vault] Writer pod failed to authenticate"
        kubectl delete pod "$VAULT_WRITER_POD" -n vault-jobs --ignore-not-found=true &>/dev/null
        return 1
    fi

    VAULT_WRITER_READY=true
    log_debug "[Vault] Writer pod ready and authenticated"
    return 0
}

# Stop and clean up the persistent Vault writer pod
_stop_vault_writer() {
    kubectl delete pod "$VAULT_WRITER_POD" -n vault-jobs --ignore-not-found=true &>/dev/null
    VAULT_WRITER_READY=false
}

# PRIVATE: Escape a string for JSON value context (RFC 7159)
# Handles: backslash, double quote, backspace, formfeed, newline, tab, carriage return
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# Write a secret to Vault using the persistent writer pod
# Usage: _vault_kv_put "secret/path" "key1=value1" "key2=value2" ...
# Uses JSON stdin to avoid shell quoting issues with special characters in values
# Returns 0 on success, 1 on failure
_vault_kv_put() {
    local secret_path="$1"
    shift
    local vault_addr="https://vault.vault.svc:8200"

    log_debug "[Vault] Writing to ${secret_path} using Kubernetes auth..."

    # Start writer pod if not already running
    if [[ "$VAULT_WRITER_READY" != "true" ]]; then
        if ! _start_vault_writer; then
            return 1
        fi
    fi

    # Build JSON payload from kv pairs (avoids shell interpolation issues)
    local json="{"
    local first=true
    for kv in "$@"; do
        local key="${kv%%=*}"
        local value="${kv#*=}"
        if [[ "$first" == "true" ]]; then
            first=false
        else
            json="${json},"
        fi
        json="${json}\"${key}\":\"$(_json_escape "$value")\""
    done
    json="${json}}"

    # Pipe JSON via stdin — vault kv put reads from stdin with -
    if printf '%s' "$json" | kubectl exec -i "$VAULT_WRITER_POD" -n vault-jobs -- /bin/sh -c "
        export VAULT_ADDR='${vault_addr}'
        export VAULT_SKIP_VERIFY=true
        export VAULT_TOKEN=\$(cat /tmp/vault-token)
        vault kv put '${secret_path}' -
    " 2>/dev/null; then
        return 0
    else
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
            if _vault_kv_put "secret/platform/minio/tf-user" \
                "access_key=${TF_MINIO_ACCESS_KEY}" \
                "secret_key=${TF_MINIO_SECRET_KEY}"; then
                log_success "[Phase 2d] MinIO tf-user credentials stored in Vault"
                stored=true
            else
                log_warning "[Phase 2d] MinIO tf-user storage attempt $attempt/$max_attempts failed"
                ((attempt++)) || true
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
        if _vault_kv_put "secret/recovery/minio/root" \
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
            if _vault_kv_put "secret/recovery/postgresql/tf-user" \
                "username=tf-user" \
                "password=${TF_VAR_postgres_tf_password}"; then
                log_success "[Phase 2d] PostgreSQL tf-user credentials stored in Vault"
                stored=true
            else
                log_warning "[Phase 2d] PostgreSQL tf-user storage attempt $attempt/$max_attempts failed"
                ((attempt++)) || true
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
        if _vault_kv_put "secret/recovery/postgresql/superuser" \
            "username=postgres" \
            "password=${TF_VAR_postgres_password}"; then
            log_success "[Phase 2d] PostgreSQL superuser credentials stored in Vault"
        else
            log_warning "[Phase 2d] Failed to store PostgreSQL superuser credentials"
        fi
    fi
}
