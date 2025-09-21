#!/bin/bash
set -e

# Enterprise Homelab Cleanup Script
# Completely removes all bootstrap components and tools for fresh start
# Usage: curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/cleanup.sh | bash -s [--force]

# Load import utility and logging library (bash 3.2+ compatible)
# Propagate LOG_LEVEL from environment if not set
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
eval "$(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/lib/imports.sh)"
smart_import "infra-management/scripts/lib/logging.sh"

log_debug "Cleanup script starting with LOG_LEVEL=$LOG_LEVEL"

cleanup_banner() {
    print_banner "🧹 Enterprise Homelab Cleanup" "⚠️  DESTRUCTIVE OPERATION"
}

confirm_cleanup() {
    echo
    log_warning "This will completely remove:"
    echo "  • k3s cluster and all data"
    echo "  • All installed tools (kubectl, terraform, helm, flux, vault)"
    echo "  • All bootstrap directories (~/homelab-bootstrap, ~/test-bootstrap)"
    echo "  • All running port-forwards and processes"
    echo
    read -p "Are you sure you want to proceed? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
}

cleanup_k3s() {
    log_info "Removing k3s cluster..."

    # Stop k3s service
    if systemctl is-active --quiet k3s 2>/dev/null; then
        log_debug "k3s service is active, stopping..."
        if sudo systemctl stop k3s; then
            log_success "k3s service stopped"
        else
            log_error "Failed to stop k3s service"
        fi
    else
        log_debug "k3s service not active"
    fi

    # Uninstall k3s completely
    if command -v k3s-uninstall.sh >/dev/null 2>&1; then
        log_debug "Running k3s-uninstall.sh..."
        if sudo k3s-uninstall.sh; then
            log_success "k3s uninstalled"
        else
            log_error "k3s uninstall script failed"
        fi
    else
        log_info "k3s uninstall script not found (may not be installed)"
    fi
}

cleanup_tools() {
    log_info "Removing installed tools..."

    local tools=("kubectl" "terraform" "helm" "flux" "vault" "mc")
    local removed_count=0

    for tool in "${tools[@]}"; do
        if [[ -f "/usr/local/bin/$tool" ]]; then
            log_debug "Attempting to remove /usr/local/bin/$tool"
            if sudo rm -f "/usr/local/bin/$tool"; then
                log_success "  ✅ $tool removed"
                ((removed_count++))
            else
                log_error "  ❌ Failed to remove $tool"
            fi
        else
            log_debug "  $tool not found"
        fi
    done

    # Clean up /tmp tools
    sudo rm -f /tmp/mc 2>/dev/null || true

    log_success "Removed $removed_count tools"
}

cleanup_directories() {
    log_info "Removing bootstrap directories..."

    local directories=(
        "$HOME/homelab-bootstrap"
        "$HOME/test-bootstrap"
        "/tmp/homelab-*"
    )

    local removed_count=0

    for dir in "${directories[@]}"; do
        if [[ -d "$dir" ]] || [[ "$dir" == *"*"* && $(ls $dir 2>/dev/null) ]]; then
            rm -rf $dir 2>/dev/null || true
            log_success "  ✅ $dir removed"
            ((removed_count++))
        else
            log_info "  ℹ️  $dir not found"
        fi
    done

    log_success "Removed $removed_count directories"
}

cleanup_processes() {
    log_info "Stopping running processes..."

    # Kill port-forwards
    if pkill -f 'kubectl port-forward' 2>/dev/null; then
        log_debug "kubectl port-forward processes killed"
    else
        log_debug "No kubectl port-forward processes found"
    fi

    if pkill -f 'port-forward' 2>/dev/null; then
        log_debug "port-forward processes killed"
    else
        log_debug "No port-forward processes found"
    fi

    # Kill any remaining k3s processes
    if pkill -f 'k3s' 2>/dev/null; then
        log_debug "k3s processes killed"
    else
        log_debug "No k3s processes found"
    fi

    # Kill terraform processes
    if pkill -f 'terraform' 2>/dev/null; then
        log_debug "terraform processes killed"
    else
        log_debug "No terraform processes found"
    fi

    log_success "Processes cleaned up"
}

verify_cleanup() {
    log_info "Verifying cleanup..."

    local issues=()

    # Check k3s
    if systemctl is-active --quiet k3s 2>/dev/null; then
        issues+=("k3s service still running")
    else
        log_success "  ✅ k3s removed"
    fi

    # Check tools
    local tools=("kubectl" "terraform" "helm" "flux" "vault")
    for tool in "${tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            issues+=("$tool still present")
        else
            log_success "  ✅ $tool removed"
        fi
    done

    # Check directories
    local directories=("$HOME/homelab-bootstrap" "$HOME/test-bootstrap")
    for dir in "${directories[@]}"; do
        if [[ -d "$dir" ]]; then
            issues+=("$dir still exists")
        else
            log_success "  ✅ $dir removed"
        fi
    done

    if [[ ${#issues[@]} -gt 0 ]]; then
        log_warning "Issues found:"
        for issue in "${issues[@]}"; do
            log_warning "  ⚠️  $issue"
        done
        return 1
    else
        log_success "All components successfully removed"
        return 0
    fi
}

print_success() {
    echo
    print_banner "🎉 CLEANUP COMPLETE!" "Your system is now ready for a fresh bootstrap" "Next steps: Run bootstrap script for fresh deployment"
}

main() {
    cleanup_banner

    # Skip confirmation if --force flag is provided
    if [[ "$1" != "--force" ]]; then
        confirm_cleanup
    fi

    log_info "Starting cleanup process..."

    cleanup_processes
    cleanup_k3s
    cleanup_tools
    cleanup_directories

    if verify_cleanup; then
        print_success
    else
        log_error "Cleanup completed with issues - manual intervention may be required"
        exit 1
    fi
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "Enterprise Homelab Cleanup Script"
        echo
        echo "Usage:"
        echo "  $0 [OPTIONS]"
        echo "  curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/cleanup.sh | bash -s [--force]"
        echo
        echo "Options:"
        echo "  --force    Skip confirmation prompt"
        echo "  --help     Show this help message"
        echo
        echo "Examples:"
        echo "  # Interactive cleanup with confirmation"
        echo "  curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/cleanup.sh | bash"
        echo
        echo "  # Force cleanup without confirmation"
        echo "  curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/cleanup.sh | bash -s --force"
        echo
        echo "This script completely removes all bootstrap components:"
        echo "  • k3s cluster and all Kubernetes resources"
        echo "  • All installed tools (kubectl, terraform, helm, flux, vault)"
        echo "  • All bootstrap directories and temporary files"
        echo "  • All running port-forwards and background processes"
        exit 0
        ;;
    --force)
        main --force
        ;;
    "")
        main
        ;;
    *)
        log_error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac