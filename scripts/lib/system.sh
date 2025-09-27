#!/bin/bash
# Shared system detection functions
# Consolidates duplicated architecture detection from multiple scripts

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