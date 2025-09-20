#!/bin/bash
# Simple library import utility
#
# Usage in scripts:
#   # Import this utility first
#   source <(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/lib/imports.sh)
#
#   # Then import any library
#   import_lib "lib/logging.sh"
#   import_lib "lib/utils.sh"
#
# Local development:
#   DEV_MODE=true ./your-script.sh
#   # Will use local filesystem instead of remote URLs
#
# Debug imports:
#   DEBUG_IMPORTS=true ./your-script.sh
#   # Will show import resolution details

get_script_dir() {
    # Find the calling script (skip this imports.sh file)
    local i=1
    while [[ "${BASH_SOURCE[$i]}" == *"imports.sh" ]]; do
        ((i++))
    done
    echo "$(cd "$(dirname "${BASH_SOURCE[$i]}")" && pwd)"
}

get_repo_info() {
    local script_dir="$(get_script_dir)"

    # Walk up to find git repo root
    local current_dir="$script_dir"
    while [[ "$current_dir" != "/" ]]; do
        if [[ -d "$current_dir/.git" ]]; then
            break
        fi
        current_dir="$(dirname "$current_dir")"
    done

    if [[ "$current_dir" == "/" ]]; then
        echo "Error: Not in a git repository" >&2
        return 1
    fi

    # Get remote origin URL and extract org/repo
    local remote_url=$(cd "$current_dir" && git remote get-url origin 2>/dev/null)
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/\.]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        echo "Error: Could not parse GitHub repo from: $remote_url" >&2
        return 1
    fi
}

import_lib() {
    local lib_path="$1"

    if [[ "${DEV_MODE:-false}" == "true" ]]; then
        # Local development: use filesystem
        local script_dir="$(get_script_dir)"
        local local_path="${script_dir}/${lib_path}"

        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Importing local: $local_path" >&2
        source "$local_path"
    else
        # Production: use remote GitHub URL
        local repo_info="$(get_repo_info)"
        local remote_url="https://raw.githubusercontent.com/${repo_info}/main/scripts/${lib_path}"

        [[ "${DEBUG_IMPORTS:-false}" == "true" ]] && echo "DEBUG: Importing remote: $remote_url" >&2
        source <(curl -sfL "$remote_url")
    fi
}