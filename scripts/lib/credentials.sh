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
        exit 1
    fi

    if [[ -z "$value" || ${#value} -lt "$length" ]]; then
        log_error "Failed to generate credential of length $length"
        exit 1
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

    # Generate access key with admin prefix and hex pattern
    _generate_secure_credential 8 "a-f0-9" MINIO_ACCESS_KEY "admin-"

    # Generate secret key
    _generate_secure_credential 24 "a-zA-Z0-9" MINIO_SECRET_KEY

    # Validate credentials format
    if [[ ! "$MINIO_ACCESS_KEY" =~ ^admin-[a-f0-9]{8}$ ]]; then
        log_error "Generated access key has invalid format: $MINIO_ACCESS_KEY"
        exit 1
    fi

    if [[ ${#MINIO_SECRET_KEY} -lt 20 ]]; then
        log_error "Generated secret key too short: ${#MINIO_SECRET_KEY} characters"
        exit 1
    fi

    # Export for Terraform
    export TF_VAR_minio_access_key="$MINIO_ACCESS_KEY"
    export TF_VAR_minio_secret_key="$MINIO_SECRET_KEY"

    return 0
}

# PRIVATE: Generate secure PostgreSQL credentials in-memory
_generate_postgresql_credentials() {
    log_info "Generating secure PostgreSQL credentials in-memory..."

    # Generate secure password
    _generate_secure_credential 24 "a-zA-Z0-9" POSTGRES_PASSWORD

    # Validate minimum length
    if [[ ${#POSTGRES_PASSWORD} -lt 20 ]]; then
        log_error "Generated PostgreSQL password too short: ${#POSTGRES_PASSWORD} characters"
        exit 1
    fi

    # Export for Terraform
    export TF_VAR_postgres_password="$POSTGRES_PASSWORD"

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
        exit 1
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
        "TF_VAR_minio_access_key" "TF_VAR_minio_secret_key"
}

_validate_postgresql_credentials() {
    _validate_credentials "PostgreSQL" "generate_bootstrap_credentials" \
        "TF_VAR_postgres_password"
}

# PRIVATE: Individual credential clearing functions
_clear_minio_credentials() {
    _clear_credentials "MinIO" \
        "TF_VAR_minio_access_key" "TF_VAR_minio_secret_key" \
        "MINIO_ACCESS_KEY" "MINIO_SECRET_KEY"
}

_clear_postgresql_credentials() {
    _clear_credentials "PostgreSQL" \
        "TF_VAR_postgres_password" "POSTGRES_PASSWORD"
}

# Generate all bootstrap credentials (MinIO + PostgreSQL)
generate_bootstrap_credentials() {
    log_info "Generating secure bootstrap credentials in-memory..."

    _generate_minio_credentials
    _generate_postgresql_credentials

    log_success "✅ Generated all bootstrap credentials in-memory (no files created)"
    return 0
}

# Validate all bootstrap credentials
validate_bootstrap_credentials() {
    log_info "Validating all bootstrap credentials..."

    _validate_minio_credentials
    _validate_postgresql_credentials

    log_success "✅ All bootstrap credentials validated"
    return 0
}

# Clear all bootstrap credentials
clear_bootstrap_credentials() {
    log_info "Clearing all bootstrap credentials from memory..."

    _clear_minio_credentials
    _clear_postgresql_credentials

    log_success "✅ All bootstrap credentials cleared from memory"
}

# Cleanup credentials on script exit (security best practice)
trap clear_bootstrap_credentials EXIT