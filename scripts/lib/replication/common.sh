#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Replication Common Utilities
# ==============================================================================

# Generate strong random alphanumeric string for passwords/secrets
generate_random_secret() {
    local length="${1:-24}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        head -c 64 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    fi
}

# Wait for a container to become responsive with timeout
wait_container_responsive() {
    local container="$1"
    local check_cmd="$2"
    local timeout_sec="${3:-30}"

    local elapsed=0
    while [ "$elapsed" -lt "$timeout_sec" ]; do
        if docker exec "$container" sh -c "$check_cmd" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}
