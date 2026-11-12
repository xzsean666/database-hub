#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Network Detection & Connectivity Library
# ==============================================================================

# Detect host IP address that can reach a peer or the outside world
detect_primary_ip() {
    local peer_ip="${1:-}"
    local detected_ip=""

    # 1. If peer IP provided, determine source IP to reach that peer
    if [ -n "$peer_ip" ] && command -v ip >/dev/null 2>&1; then
        detected_ip=$(ip route get "$peer_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
    fi

    # 2. Try default gateway route
    if [ -z "$detected_ip" ] && command -v ip >/dev/null 2>&1; then
        detected_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
    fi

    # 3. Try hostname -I
    if [ -z "$detected_ip" ] && command -v hostname >/dev/null 2>&1; then
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi

    # 4. Fallback to 127.0.0.1
    if [ -z "$detected_ip" ]; then
        detected_ip="127.0.0.1"
    fi

    echo "$detected_ip"
}

# Test TCP port connectivity with timeout (default 3 seconds)
test_tcp_port() {
    local host="$1"
    local port="$2"
    local timeout_sec="${3:-3}"

    if [ -z "$host" ] || [ -z "$port" ]; then
        return 1
    fi

    # Method 1: Bash /dev/tcp
    if timeout "$timeout_sec" bash -c "true > /dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    fi

    # Method 2: nc (netcat)
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w "$timeout_sec" "$host" "$port" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}
