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

# Detect and cache system architecture (only runs once per session)
detect_system_architecture() {
    # Return early if already detected
    if [[ -n "${DETECTED_ARCH:-}" && -n "${DETECTED_OS:-}" ]]; then
        return 0
    fi

    log_info "Detecting system architecture..."

    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$arch" in
        x86_64) DETECTED_ARCH="amd64" ;;
        arm64|aarch64) DETECTED_ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    case "$os" in
        linux) DETECTED_OS="linux" ;;
        darwin) DETECTED_OS="darwin" ;;
        *)
            log_error "Unsupported operating system: $os"
            exit 1
            ;;
    esac

    log_success "✅ Detected: $DETECTED_OS/$DETECTED_ARCH"
    export DETECTED_ARCH
    export DETECTED_OS
}