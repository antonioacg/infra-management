#!/bin/bash
# Simple library import utility
#
# Usage in scripts:
#   # Import this utility first (bash 3.2+ compatible)
#   eval "$(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/lib/imports.sh)"
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
        # Local development: find repo root by looking for repo name in script path
        local script_dir="$(get_script_dir)"
        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Script dir: $script_dir" >&2
        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Looking for repo: $repo_name" >&2

        # Find where repo name appears in the script path
        local repo_root="${script_dir}"
        while [[ "$repo_root" != "/" ]]; do
            [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Checking: $repo_root (basename: $(basename "$repo_root"))" >&2
            if [[ "$(basename "$repo_root")" == "$repo_name" ]]; then
                [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Found repo root: $repo_root" >&2
                break
            fi
            repo_root="$(dirname "$repo_root")"
        done

        if [[ "$repo_root" == "/" ]]; then
            echo "Error: Could not find repo '$repo_name' in script path: $script_dir" >&2
            return 1
        fi

        # Build path relative to repo root
        local relative_path="${lib_path#*/}"  # Strip repo name
        local local_path="${repo_root}/${relative_path}"
        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Relative path: $relative_path" >&2
        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Final local path: $local_path" >&2

        source "$local_path"
    else
        # Production: use remote GitHub URL
        local remote_url="https://raw.githubusercontent.com/${GITHUB_ORG}/${repo_name}/main/${lib_path#*/}"

        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Importing remote: $remote_url" >&2
        source <(curl -sfL "$remote_url")
    fi
}