#!/bin/bash
# Enterprise Platform Logging Library
# Centralized logging functions for consistent output across all scripts
# Usage: source <(curl -sfL https://raw.githubusercontent.com/antonioacg/infra-management/main/scripts/lib/logging.sh)
#
# Banner/Box Configuration:
# - Default width: 120 characters
# - Format: ╔═══...═══╗ with ║ borders
# - Clients can override banner width with BANNER_WIDTH environment variable

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration (can be overridden by scripts)
LOG_LEVEL=${LOG_LEVEL:-INFO}
LOG_TIMESTAMPS=${LOG_TIMESTAMPS:-false}
BANNER_WIDTH=${BANNER_WIDTH:-120}

# Internal function to get timestamp if enabled
_get_timestamp() {
    if [[ "$LOG_TIMESTAMPS" == "true" ]]; then
        local ns="$(date '+%N' 2>/dev/null)"
        if [[ "$ns" =~ ^[0-9]+$ ]]; then
            # GNU date: show milliseconds
            local ms="${ns:0:3}"
            echo "[$(date '+%H:%M:%S').${ms}] "
        else
            # macOS: use perl for milliseconds
            local ts=$(perl -MPOSIX=strftime -MTime::HiRes=gettimeofday -le \
                '($s,$ms)=gettimeofday; print strftime("[%H:%M:%S.",localtime($s)),sprintf("%03d] ",$ms/1000)')
            echo "$ts"
        fi
    fi
}

# Core logging functions (no emojis - clients decide)
log_info() {
    echo -e "$(_get_timestamp)${BLUE}$1${NC}"
}

log_success() {
    echo -e "$(_get_timestamp)${GREEN}$1${NC}"
}

log_warning() {
    echo -e "$(_get_timestamp)${YELLOW}$1${NC}"
}

log_error() {
    echo -e "$(_get_timestamp)${RED}$1${NC}" >&2
}

log_phase() {
    echo -e "$(_get_timestamp)${CYAN}$1${NC}"
}

# Enhanced logging functions with levels
log_debug() {
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
        echo -e "$(_get_timestamp)${CYAN}DEBUG: $1${NC}" >&2
    fi
}

log_trace() {
    if [[ "$LOG_LEVEL" == "TRACE" ]]; then
        echo -e "$(_get_timestamp)${CYAN}TRACE: $1${NC}" >&2
    fi
}

# Utility functions for consistent formatting
print_banner() {
    local title="$1"
    local subtitle="$2"
    local info="$3"
    local width=$((BANNER_WIDTH - 2))  # Account for border characters

    echo -e "${GREEN}"
    printf "╔"
    printf "%*s" $((BANNER_WIDTH - 2)) | tr ' ' '═'
    printf "╗\n"

    printf "║%*s║\n" $width "$(printf "%*s" $(((width + ${#title}) / 2)) "$title")"

    if [[ -n "$subtitle" ]]; then
        printf "║%*s║\n" $width "$(printf "%*s" $(((width + ${#subtitle}) / 2)) "$subtitle")"
    fi

    if [[ -n "$info" ]]; then
        printf "║%*s║\n" $width "$(printf "%*s" $(((width + ${#info}) / 2)) "$info")"
    fi

    printf "╚"
    printf "%*s" $((BANNER_WIDTH - 2)) | tr ' ' '═'
    printf "╝\n"
    echo -e "${NC}"
}

print_success_box() {
    local title="$1"
    shift
    local lines=("$@")
    local width=$((BANNER_WIDTH - 2))

    echo
    echo -e "${GREEN}"
    printf "╔"
    printf "%*s" $((BANNER_WIDTH - 2)) | tr ' ' '═'
    printf "╗\n"

    printf "║%*s║\n" $width "$(printf "%*s" $(((width + ${#title}) / 2)) "$title")"

    printf "╠"
    printf "%*s" $((BANNER_WIDTH - 2)) | tr ' ' '═'
    printf "╣\n"

    for line in "${lines[@]}"; do
        printf "║  %-*s║\n" $((width - 2)) "$line"
    done

    printf "╚"
    printf "%*s" $((BANNER_WIDTH - 2)) | tr ' ' '═'
    printf "╝\n"
    echo -e "${NC}"
}

# Progress indicator
show_progress() {
    local current="$1"
    local total="$2"
    local message="$3"
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))

    printf "\r${BLUE}%s [" "$message"
    printf "%*s" $completed | tr ' ' '='
    printf "%*s" $remaining | tr ' ' '-'
    printf "] %d%% (%d/%d)${NC}" $percentage $current $total

    if [[ $current -eq $total ]]; then
        echo
    fi
}

# Set log level from environment or parameter
set_log_level() {
    case "${1:-$LOG_LEVEL}" in
        TRACE|DEBUG|INFO|WARN|ERROR)
            LOG_LEVEL="$1"
            ;;
        *)
            log_warning "Invalid log level: $1. Using INFO"
            LOG_LEVEL="INFO"
            ;;
    esac
}

# Enable/disable timestamps
set_timestamps() {
    case "${1:-false}" in
        true|TRUE|1|yes|YES)
            LOG_TIMESTAMPS="true"
            ;;
        *)
            LOG_TIMESTAMPS="false"
            ;;
    esac
}

# Library initialization message
log_debug "Enterprise Platform Logging Library loaded (Level: $LOG_LEVEL, Timestamps: $LOG_TIMESTAMPS)"