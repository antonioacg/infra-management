#!/bin/bash
# Network utilities library
# Provides robust download functions with retry logic and error handling

# Streamlined curl function with retry logic
# Usage: curl_with_retry URL [OUTPUT_FILE] [MAX_ATTEMPTS]
# If OUTPUT_FILE is omitted or "-", outputs to stdout for piping
curl_with_retry() {
    local url="$1"
    local output_file="${2:--}"  # Default to stdout
    local max_attempts="${3:-3}"

    # Auto-generate description from URL
    local description="${output_file}"
    [[ "$output_file" == "-" ]] && description="$(basename "$url")"

    log_debug "Downloading from: $url"

    for attempt in $(seq 1 $max_attempts); do
        log_info "📥 Download attempt $attempt/$max_attempts for $description..."

        local curl_cmd="curl -sSfL --connect-timeout 30 --max-time 300 --retry 1"

        if [[ "$output_file" == "-" ]]; then
            # Output to stdout for piping
            if $curl_cmd "$url"; then
                log_success "✅ $description downloaded successfully"
                return 0
            fi
        else
            # Save to file
            if $curl_cmd -o "$output_file" "$url"; then
                if [[ -f "$output_file" && -s "$output_file" ]]; then
                    local size=$(ls -lh "$output_file" 2>/dev/null | awk '{print $5}' || echo "unknown")
                    log_success "✅ $description downloaded successfully ($size)"
                    return 0
                else
                    log_warning "Downloaded file is empty or missing"
                    rm -f "$output_file"
                fi
            fi
        fi

        log_warning "Download attempt $attempt failed"
        [[ $attempt -lt $max_attempts ]] && sleep 2
    done

    log_error "❌ Failed to download $description after $max_attempts attempts"
    return 1
}