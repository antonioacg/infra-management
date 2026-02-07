#!/bin/bash
# Shared system utilities
# System detection, trap stacking, and other system-level utilities

# Stack a new trap handler onto an existing trap
# Usage: stack_trap "command" [SIGNAL]
# Default signal is EXIT
stack_trap() {
    local new_trap=$1
    local signal=${2:-EXIT}

    # Get existing trap command for this signal
    local existing_trap
    existing_trap=$(trap -p "$signal" | sed -n "s/trap -- '\(.*\)' $signal/\1/p")

    # Stack: run existing trap first, then new trap
    if [[ -n "$existing_trap" ]]; then
        # shellcheck disable=SC2064
        trap "$existing_trap; $new_trap" "$signal"
    else
        # shellcheck disable=SC2064
        trap "$new_trap" "$signal"
    fi
}

# Rename a function to preserve it before it gets overwritten
# Usage: rename_function "old_name" "new_name"
# Creates an independent copy of the function with a new name using declare -f
rename_function() {
    local old_name=$1
    local new_name=$2

    # Check if original function exists
    if ! declare -f "$old_name" >/dev/null 2>&1; then
        return 1  # Function doesn't exist
    fi

    # Create independent copy with new name
    # Uses declare -f to get full function definition, sed to rename it
    eval "$(declare -f "$old_name" | sed "1s/^${old_name} /${new_name} /")"
}

# Detect and cache system architecture (only runs once per session)
detect_system_architecture() {
    # Return early if already detected
    if [[ -n "${DETECTED_ARCH:-}" && -n "${DETECTED_OS:-}" ]]; then
        return 0
    fi

    log_info "Detecting system architecture..."

    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$arch" in
        x86_64) DETECTED_ARCH="amd64" ;;
        arm64|aarch64) DETECTED_ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    case "$os" in
        linux) DETECTED_OS="linux" ;;
        darwin) DETECTED_OS="darwin" ;;
        *)
            log_error "Unsupported operating system: $os"
            return 1
            ;;
    esac

    log_success "✅ Detected: $DETECTED_OS/$DETECTED_ARCH"
    export DETECTED_ARCH
    export DETECTED_OS
}