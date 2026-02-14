#!/bin/bash
# Secure credential management library
# Generates credentials in-memory, no file persistence

# PRIVATE: Generic secure credential generator
_generate_secure_credential() {
    local length="$1"
    local pattern="${2:-a-zA-Z0-9}"  # Default alphanumeric
    local output_var="$3"
    local prefix="${4:-}"  # Optional prefix

    local value
    if command -v openssl >/dev/null 2>&1; then
        # Generate more entropy and filter to pattern
        value=$(openssl rand -base64 64 | LC_ALL=C tr -dc "$pattern" | head -c "$length")
    elif [[ -r /dev/urandom ]]; then
        value=$(cat /dev/urandom | LC_ALL=C tr -dc "$pattern" | fold -w "$length" | head -n 1)
    else
        log_error "Cannot generate secure credentials: no entropy source available"
        return 1
    fi

    if [[ -z "$value" || ${#value} -lt "$length" ]]; then
        log_error "Failed to generate credential of length $length"
        return 1
    fi

    # Add prefix if provided
    if [[ -n "$prefix" ]]; then
        value="${prefix}${value}"
    fi

    eval "$output_var='$value'"
}

# PRIVATE: Generate secure MinIO credentials in-memory
_generate_minio_credentials() {
    log_info "Generating secure MinIO credentials in-memory..."

    # Generate root user with admin prefix and hex pattern
    _generate_secure_credential 8 "a-f0-9" MINIO_ROOT_USER "admin-"

    # Generate root password
    _generate_secure_credential 24 "a-zA-Z0-9" MINIO_ROOT_PASSWORD

    # Validate credentials format
    if [[ ! "$MINIO_ROOT_USER" =~ ^admin-[a-f0-9]{8}$ ]]; then
        log_error "Generated root user has invalid format: $MINIO_ROOT_USER"
        return 1
    fi

    if [[ ${#MINIO_ROOT_PASSWORD} -lt 20 ]]; then
        log_error "Generated root password too short: ${#MINIO_ROOT_PASSWORD} characters"
        return 1
    fi

    # Export for Terraform
    export TF_VAR_minio_root_user="$MINIO_ROOT_USER"
    export TF_VAR_minio_root_password="$MINIO_ROOT_PASSWORD"

    return 0
}

# PRIVATE: Generate secure PostgreSQL credentials in-memory
_generate_postgresql_credentials() {
    log_info "Generating secure PostgreSQL credentials in-memory..."

    # Generate secure password for superuser
    _generate_secure_credential 24 "a-zA-Z0-9" POSTGRES_PASSWORD

    # Validate minimum length
    if [[ ${#POSTGRES_PASSWORD} -lt 20 ]]; then
        log_error "Generated PostgreSQL password too short: ${#POSTGRES_PASSWORD} characters"
        return 1
    fi

    # Export for Terraform
    export TF_VAR_postgres_password="$POSTGRES_PASSWORD"

    return 0
}

# PRIVATE: Generate secure PostgreSQL tf-user credentials in-memory
_generate_postgresql_tf_credentials() {
    log_info "Generating secure PostgreSQL tf-user credentials in-memory..."

    # Generate secure password for tf-user (terraform state locking)
    _generate_secure_credential 24 "a-zA-Z0-9" POSTGRES_TF_PASSWORD

    # Validate minimum length
    if [[ ${#POSTGRES_TF_PASSWORD} -lt 20 ]]; then
        log_error "Generated PostgreSQL tf-user password too short: ${#POSTGRES_TF_PASSWORD} characters"
        return 1
    fi

    # Export for Terraform
    export TF_VAR_postgres_tf_password="$POSTGRES_TF_PASSWORD"

    return 0
}

# PRIVATE: Generate state encryption passphrase in-memory
_generate_encryption_passphrase() {
    log_info "Generating state encryption passphrase in-memory..."
    _generate_secure_credential 48 "a-zA-Z0-9" ENCRYPTION_PASSPHRASE
    if [[ ${#ENCRYPTION_PASSPHRASE} -lt 40 ]]; then
        log_error "Generated encryption passphrase too short: ${#ENCRYPTION_PASSPHRASE} characters"
        return 1
    fi
    export ENCRYPTION_PASSPHRASE
    return 0
}

# PRIVATE: Generic credential validation helper
_validate_credentials() {
    local service_name="$1"
    local generator_func="$2"
    shift 2
    local vars=("$@")

    local missing_vars=()
    for var in "${vars[@]}"; do
        [[ -z "${!var:-}" ]] && missing_vars+=("$var")
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing $service_name credential variables: ${missing_vars[*]}"
        log_error "Run $generator_func() before deploying"
        return 1
    fi

    return 0
}

# PRIVATE: Generic credential clearing helper
_clear_credentials() {
    local service_name="$1"
    shift
    local vars=("$@")

    for var in "${vars[@]}"; do
        unset "$var"
    done
}

# PRIVATE: Individual credential validation functions
_validate_minio_credentials() {
    _validate_credentials "MinIO" "generate_bootstrap_credentials" \
        "TF_VAR_minio_root_user" "TF_VAR_minio_root_password"
}

_validate_postgresql_credentials() {
    _validate_credentials "PostgreSQL" "generate_bootstrap_credentials" \
        "TF_VAR_postgres_password" "TF_VAR_postgres_tf_password"
}

_validate_encryption_passphrase() {
    _validate_credentials "Encryption" "generate_bootstrap_credentials" \
        "ENCRYPTION_PASSPHRASE"
}

# PRIVATE: Individual credential clearing functions
_clear_minio_credentials() {
    _clear_credentials "MinIO" \
        "TF_VAR_minio_root_user" "TF_VAR_minio_root_password" \
        "MINIO_ROOT_USER" "MINIO_ROOT_PASSWORD"
}

_clear_postgresql_credentials() {
    _clear_credentials "PostgreSQL" \
        "TF_VAR_postgres_password" "POSTGRES_PASSWORD" \
        "TF_VAR_postgres_tf_password" "POSTGRES_TF_PASSWORD"
}

_clear_encryption_credentials() {
    _clear_credentials "Encryption" \
        "ENCRYPTION_PASSPHRASE"
}

# Generate all bootstrap credentials (MinIO + PostgreSQL + Encryption)
generate_bootstrap_credentials() {
    log_info "Generating secure bootstrap credentials in-memory..."

    _generate_minio_credentials
    _generate_postgresql_credentials
    _generate_postgresql_tf_credentials
    _generate_encryption_passphrase

    log_success "✅ Generated all bootstrap credentials in-memory (no files created)"
    return 0
}

# Validate all bootstrap credentials
validate_bootstrap_credentials() {
    log_info "Validating all bootstrap credentials..."

    _validate_minio_credentials
    _validate_postgresql_credentials
    _validate_encryption_passphrase

    log_success "✅ All bootstrap credentials validated"
    return 0
}

# Clear all bootstrap credentials
clear_bootstrap_credentials() {
    log_info "Clearing all bootstrap credentials from memory..."

    _clear_minio_credentials
    _clear_postgresql_credentials
    _clear_encryption_credentials

    log_success "✅ All bootstrap credentials cleared from memory"
}

# Validate VAULT_SECRET_* env vars (fail-fast, called from Phase 0)
# Checks encoding convention (__), path prefix, and non-empty value.
# Returns 0 when no vars present (they are optional) or all valid.
validate_vault_secrets() {
    local errors=0
    local count=0

    while IFS='=' read -r name value; do
        if [[ "$name" == VAULT_SECRET_* ]]; then
            ((count++))
            local encoded="${name#VAULT_SECRET_}"

            # Must use __ (double underscore) to encode path separators
            if [[ "$encoded" != *__* ]]; then
                log_error "VAULT_SECRET invalid encoding: $name (use __ to separate path segments, e.g. VAULT_SECRET_production__app__key)"
                ((errors++))
                continue
            fi

            local path="${encoded//__//}"

            # Must start with a valid trust domain prefix
            case "$path" in
                platform/*|production/*|recovery/*) ;;
                *)
                    log_error "VAULT_SECRET invalid path prefix: $name → $path (must start with platform/, production/, or recovery/)"
                    ((errors++))
                    continue
                    ;;
            esac

            # Value must not be empty
            if [[ -z "$value" ]]; then
                log_error "VAULT_SECRET empty value: $name"
                ((errors++))
                continue
            fi
        fi
    done < <(env | grep "^VAULT_SECRET_" || true)

    if [[ $errors -gt 0 ]]; then
        log_error "Found $errors invalid VAULT_SECRET_* variable(s)"
        return 1
    fi

    if [[ $count -gt 0 ]]; then
        log_success "[Phase 0] Validated $count VAULT_SECRET_* variable(s)"
    fi

    return 0
}

# Collect all VAULT_SECRET_* env vars
# Convention: VAULT_SECRET_<namespace>__<path>=<value>
#   Double underscore (__) encodes path separator (/)
#   POSIX env var names cannot contain /
#
# Example:
#   VAULT_SECRET_production__cloudflare__token=xxx
#   -> Vault path: production/cloudflare/token
#   -> Key name:   token (last path segment)
#   -> Value:      xxx
#
# Output: one "path key=value" per line
_collect_vault_secrets() {
    while IFS='=' read -r name value; do
        if [[ "$name" == VAULT_SECRET_* ]]; then
            local encoded="${name#VAULT_SECRET_}"
            local path="${encoded//__//}"  # Replace __ with /
            local key="${path##*/}"        # Last segment = key name
            # Validate namespace prefix (defensive — Phase 0 is the primary gate)
            case "$path" in
                platform/*|production/*|recovery/*)
                    echo "${path} ${key}=${value}"
                    ;;
                *)
                    log_warning "Skipping invalid VAULT_SECRET path: $path (must start with platform/, production/, or recovery/)"
                    continue
                    ;;
            esac
        fi
    done < <(env | grep "^VAULT_SECRET_" || true)
}
