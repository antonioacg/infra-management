#!/bin/bash
# Don't use set -e as cleanup operations may have expected failures
# We handle errors explicitly with proper logging

# Enterprise Homelab Cleanup Script
# Completely removes all bootstrap components and tools for fresh start
# Usage: curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/${GIT_REF:-main}/scripts/cleanup.sh | bash -s [--force]

# Load import utility and logging library (bash 3.2+ compatible)
# Propagate LOG_LEVEL from environment if not set
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
eval "$(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/${GIT_REF:-main}/scripts/lib/imports.sh)"
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

cleanup_kubectl_config() {
    local specified_contexts="$1"
    log_info "Cleaning up kubectl config..."

    # Only clean up if kubectl and config exist
    if ! command -v kubectl >/dev/null 2>&1 || [[ ! -f ~/.kube/config ]]; then
        log_debug "kubectl or config not found, skipping kubectl config cleanup"
        return
    fi

    local contexts_to_clean=""

    if [[ -n "$specified_contexts" ]]; then
        # Use specified contexts (comma-separated)
        contexts_to_clean=$(echo "$specified_contexts" | tr ',' '\n')
        log_debug "Using specified contexts: $specified_contexts"
    else
        # Find all k3s-related contexts (default behavior)
        contexts_to_clean=$(kubectl config get-contexts -o name 2>/dev/null | grep -E '^k3s-default' || echo "")
        log_debug "Auto-discovered k3s contexts"
    fi

    if [[ -z "$contexts_to_clean" ]]; then
        log_debug "No contexts found to clean, skipping kubectl config cleanup"
        return
    fi

    local cleaned_count=0

    # Clean up each context
    while IFS= read -r context; do
        [[ -z "$context" ]] && continue

        # Check if context actually exists
        if ! kubectl config get-contexts "$context" >/dev/null 2>&1; then
            log_debug "Context '$context' not found, skipping"
            continue
        fi

        log_debug "Cleaning up context: $context"

        # Get cluster and user for this context
        local cluster user
        cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$context')].context.cluster}" 2>/dev/null || echo "")
        user=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$context')].context.user}" 2>/dev/null || echo "")

        # Remove context
        if kubectl config delete-context "$context" >/dev/null 2>&1; then
            log_success "  ✅ Removed context: $context"
            ((cleaned_count++))
        else
            log_debug "  Context $context not found or already removed"
        fi

        # Remove cluster if it has the same name pattern
        if [[ -n "$cluster" && "$cluster" =~ k3s-default ]]; then
            if kubectl config delete-cluster "$cluster" >/dev/null 2>&1; then
                log_success "  ✅ Removed cluster: $cluster"
            else
                log_debug "  Cluster $cluster not found or already removed"
            fi
        fi

        # Remove user if it has the same name pattern
        if [[ -n "$user" && "$user" =~ k3s-default ]]; then
            if kubectl config delete-user "$user" >/dev/null 2>&1; then
                log_success "  ✅ Removed user: $user"
            else
                log_debug "  User $user not found or already removed"
            fi
        fi
    done <<< "$contexts_to_clean"

    if [[ $cleaned_count -gt 0 ]]; then
        log_success "kubectl config cleanup complete ($cleaned_count contexts removed)"

        # Validate and fix current-context after removing contexts
        local current_context
        current_context=$(kubectl config current-context 2>/dev/null || echo "")

        if [[ -n "$current_context" ]]; then
            # Check if current context actually exists
            if ! kubectl config get-contexts "$current_context" >/dev/null 2>&1; then
                log_warning "Current context '$current_context' is invalid, resetting..."

                # Find first available context that's not k3s-related
                local fallback_context
                fallback_context=$(kubectl config get-contexts -o name 2>/dev/null | grep -v '^k3s-default' | head -1)

                if [[ -n "$fallback_context" ]]; then
                    kubectl config use-context "$fallback_context" >/dev/null 2>&1
                    log_success "  ✅ Reset current context to: $fallback_context"
                else
                    log_warning "  ⚠️  No valid non-k3s contexts remaining"
                    # Remove kubeconfig file if no contexts left
                    if [[ -f ~/.kube/config ]]; then
                        rm ~/.kube/config
                        log_success "  ✅ Removed empty kubeconfig file"
                    fi
                fi
            fi
        fi

        # Check if any contexts remain at all
        local remaining_contexts
        remaining_contexts=$(kubectl config get-contexts -o name 2>/dev/null | wc -l)

        if [[ "$remaining_contexts" -eq 0 ]]; then
            log_warning "No contexts remaining in kubeconfig"
            if [[ -f ~/.kube/config ]]; then
                rm ~/.kube/config
                log_success "  ✅ Removed empty kubeconfig file"
            fi
        else
            # Validate kubeconfig integrity
            if ! kubectl config view >/dev/null 2>&1; then
                log_warning "kubeconfig file validation failed - may need manual intervention"
            fi
        fi
    else
        log_debug "No contexts were removed"
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
            if sudo rm "/usr/local/bin/$tool" 2>/dev/null; then
                # Verify it was actually removed
                if [[ ! -f "/usr/local/bin/$tool" ]]; then
                    log_success "  ✅ $tool removed"
                    ((removed_count++))
                else
                    log_error "  ❌ Failed to remove $tool (still exists)"
                fi
            else
                log_error "  ❌ Failed to remove $tool"
            fi
        else
            log_debug "  $tool not found in /usr/local/bin"
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
        if [[ -d "$dir" ]]; then
            log_debug "Removing directory: $dir"
            if rm -rf "$dir" 2>/dev/null; then
                log_success "  ✅ $dir removed"
                ((removed_count++))
            else
                log_error "  ❌ Failed to remove $dir"
            fi
        elif [[ "$dir" == *"*"* ]]; then
            # Handle wildcard patterns
            log_debug "Checking wildcard pattern: $dir"
            if ls $dir >/dev/null 2>&1; then
                if rm -rf $dir 2>/dev/null; then
                    log_success "  ✅ $dir pattern removed"
                    ((removed_count++))
                else
                    log_error "  ❌ Failed to remove $dir pattern"
                fi
            else
                log_debug "  No matches for pattern $dir"
            fi
        else
            log_debug "  $dir not found"
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

    # Check tools in /usr/local/bin (cleanup target)
    local tools=("kubectl" "terraform" "helm" "flux" "vault")
    for tool in "${tools[@]}"; do
        if [[ -f "/usr/local/bin/$tool" ]]; then
            issues+=("$tool still present in /usr/local/bin")
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
    # Parse arguments
    local force_cleanup=false
    local kubectl_contexts=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force_cleanup=true
                shift
                ;;
            --contexts=*)
                kubectl_contexts="${1#*=}"
                shift
                ;;
            *)
                log_error "Unknown parameter: $1"
                echo "Usage: $0 [--force] [--contexts=context1,context2,...]"
                echo "  --force      Skip confirmation prompts"
                echo "  --contexts   Comma-separated list of kubectl contexts to remove"
                echo "               Default: automatically finds k3s-default* contexts"
                exit 1
                ;;
        esac
    done

    cleanup_banner

    # Skip confirmation if --force flag is provided
    if [[ "$force_cleanup" != "true" ]]; then
        confirm_cleanup
    fi

    log_info "Starting cleanup process..."

    cleanup_processes
    cleanup_kubectl_config "$kubectl_contexts"
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
        echo "  curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/${GIT_REF:-main}/scripts/cleanup.sh | bash -s [--force]"
        echo
        echo "Options:"
        echo "  --force      Skip confirmation prompt"
        echo "  --contexts   Comma-separated list of kubectl contexts to remove"
        echo "  --help       Show this help message"
        echo
        echo "Examples:"
        echo "  # Interactive cleanup with confirmation"
        echo "  curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/${GIT_REF:-main}/scripts/cleanup.sh | bash"
        echo
        echo "  # Force cleanup without confirmation"
        echo "  curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/${GIT_REF:-main}/scripts/cleanup.sh | bash -s --force"
        echo
        echo "This script completely removes all bootstrap components:"
        echo "  • k3s cluster and all Kubernetes resources"
        echo "  • All installed tools (kubectl, terraform, helm, flux, vault)"
        echo "  • All bootstrap directories and temporary files"
        echo "  • All running port-forwards and background processes"
        exit 0
        ;;
    *)
        # Pass all arguments to main function for proper parsing
        main "$@"
        ;;
esac