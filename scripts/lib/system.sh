#!/bin/bash
# Shared system detection functions
# Extracts duplicated code between Phase 0 and Phase 1

detect_system_architecture() {
    log_info "Detecting system architecture..."

    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$arch" in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    case "$os" in
        linux) OS="linux" ;;
        darwin) OS="darwin" ;;
        *)
            log_error "Unsupported operating system: $os"
            exit 1
            ;;
    esac

    log_success "✅ Detected: $OS/$ARCH"
    export DETECTED_ARCH="$ARCH"
    export DETECTED_OS="$OS"
}