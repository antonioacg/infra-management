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

# Dynamic banner width detection
get_banner_width() {
    local max_width=120
    local min_width=60
    local terminal_width

    # Try multiple methods to get terminal width
    if [[ -n "${COLUMNS:-}" ]]; then
        terminal_width=$COLUMNS
    elif command -v tput >/dev/null 2>&1; then
        terminal_width=$(tput cols 2>/dev/null || echo "80")
    elif [[ -n "${TERM:-}" ]] && command -v stty >/dev/null 2>&1; then
        terminal_width=$(stty size 2>/dev/null | cut -d' ' -f2 || echo "80")
    else
        terminal_width=80
    fi

    local available_width=$((terminal_width - 4))  # Leave some margin

    if [[ $available_width -lt $min_width ]]; then
        echo $min_width
    elif [[ $available_width -gt $max_width ]]; then
        echo $max_width
    else
        echo $available_width
    fi
}

BANNER_WIDTH=${BANNER_WIDTH:-$(get_banner_width)}

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

# Core logging functions (clean, no emojis)
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

    # Center the title
    local title_padding=$(((width - ${#title}) / 2))
    printf "║%*s%s%*s║\n" $title_padding "" "$title" $((width - title_padding - ${#title})) ""

    if [[ -n "$subtitle" ]]; then
        local subtitle_padding=$(((width - ${#subtitle}) / 2))
        printf "║%*s%s%*s║\n" $subtitle_padding "" "$subtitle" $((width - subtitle_padding - ${#subtitle})) ""
    fi

    if [[ -n "$info" ]]; then
        local info_padding=$(((width - ${#info}) / 2))
        printf "║%*s%s%*s║\n" $info_padding "" "$info" $((width - info_padding - ${#info})) ""
    fi

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