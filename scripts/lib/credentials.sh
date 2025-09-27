#!/bin/bash
# Secure credential management library
# Generates credentials in-memory, no file persistence

generate_minio_credentials() {
    local access_key_length=16
    local secret_key_length=32

    log_info "Generating secure MinIO credentials in-memory..."

    # Generate cryptographically secure random credentials (inspired by generate-credentials.sh)
    if command -v openssl >/dev/null 2>&1; then
        # Use patterns from existing script but generate in-memory only
        MINIO_ACCESS_KEY="admin-$(openssl rand -hex 4)"
        MINIO_SECRET_KEY="$(openssl rand -base64 32 | tr -d '=+/' | head -c 24)"
    elif [[ -r /dev/urandom ]]; then
        # Fallback for systems without openssl
        MINIO_ACCESS_KEY="admin-$(cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | fold -w 8 | head -n 1)"
        MINIO_SECRET_KEY=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 24 | head -n 1)
    else
        log_error "Cannot generate secure credentials: no entropy source available"
        log_error "Required: openssl command or /dev/urandom access"
        exit 1
    fi

    # Validate credentials were generated
    if [[ -z "$MINIO_ACCESS_KEY" || -z "$MINIO_SECRET_KEY" ]]; then
        log_error "Failed to generate MinIO credentials"
        log_error "Access key length: ${#MINIO_ACCESS_KEY}, Secret key length: ${#MINIO_SECRET_KEY}"
        exit 1
    fi

    # Validate credential format and length
    if [[ ! "$MINIO_ACCESS_KEY" =~ ^admin-[a-f0-9]{8}$ ]]; then
        log_error "Generated access key has invalid format: $MINIO_ACCESS_KEY"
        exit 1
    fi

    if [[ ${#MINIO_SECRET_KEY} -lt 20 ]]; then
        log_error "Generated secret key too short: ${#MINIO_SECRET_KEY} characters"
        exit 1
    fi

    log_success "✅ Generated secure MinIO credentials in-memory (no files created)"

    # Export for Terraform
    export TF_VAR_minio_access_key="$MINIO_ACCESS_KEY"
    export TF_VAR_minio_secret_key="$MINIO_SECRET_KEY"

    return 0
}

validate_required_credentials() {
    local missing_vars=()

    [[ -z "${TF_VAR_minio_access_key:-}" ]] && missing_vars+=("TF_VAR_minio_access_key")
    [[ -z "${TF_VAR_minio_secret_key:-}" ]] && missing_vars+=("TF_VAR_minio_secret_key")

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required credential variables: ${missing_vars[*]}"
        log_error "Run generate_minio_credentials() before deploying"
        exit 1
    fi

    log_success "✅ All required credentials validated"
    return 0
}

clear_credentials() {
    log_info "Clearing credentials from memory..."

    # Clear environment variables
    unset TF_VAR_minio_access_key
    unset TF_VAR_minio_secret_key
    unset MINIO_ACCESS_KEY
    unset MINIO_SECRET_KEY

    log_success "✅ Credentials cleared from memory"
}

# Cleanup credentials on script exit (security best practice)
trap clear_credentials EXIT