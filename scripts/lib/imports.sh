#!/bin/bash
# Simple library import utility
#
# Usage in scripts:
#   # Import this utility first
#   source <(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/lib/imports.sh)
#
#   # Then import any library
#   smart_import "infra-management/scripts/lib/logging.sh"
#   smart_import "infra-management/scripts/lib/utils.sh"
#
# Local development:
#   USE_LOCAL_IMPORTS=true ./your-script.sh
#   # Will use local filesystem instead of remote URLs
#
# Debug imports:
#   DEBUG_IMPORTS=true ./your-script.sh
#   # Will show import resolution details

# Configuration
GITHUB_ORG="antonioacg"

get_script_dir() {
    # Find the calling script (skip this imports.sh file)
    local i=1
    while [[ "${BASH_SOURCE[$i]}" == *"imports.sh" ]]; do
        ((i++))
    done
    echo "$(cd "$(dirname "${BASH_SOURCE[$i]}")" && pwd)"
}

smart_import() {
    local lib_path="$1"

    # Extract repo name from path (e.g. "infra-management/scripts/lib/logging.sh" -> "infra-management")
    local repo_name="${lib_path%%/*}"

    if [[ "${USE_LOCAL_IMPORTS:-false}" == "true" ]]; then
        # Local development: use filesystem relative to repo root
        local script_dir="$(get_script_dir)"

        # Walk up to find git repo root
        local repo_root="$script_dir"
        while [[ "$repo_root" != "/" && ! -d "$repo_root/.git" ]]; do
            repo_root="$(dirname "$repo_root")"
        done

        local local_path="${repo_root}/${lib_path}"
        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Importing local: $local_path" >&2
        source "$local_path"
    else
        # Production: use remote GitHub URL
        local remote_url="https://raw.githubusercontent.com/${GITHUB_ORG}/${repo_name}/main/${lib_path#*/}"

        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Importing remote: $remote_url" >&2
        source <(curl -sfL "$remote_url")
    fi
}