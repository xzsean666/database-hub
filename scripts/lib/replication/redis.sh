#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Redis Replication Driver
# Supports: In-place Master Promotion, Native replicaof Bootstrap, Lag Check
# ==============================================================================

redis_make_master() {
    local env_file="$1"
    local inst_id="${INSTANCE_ID:-database-hub}"
    local container="${REDIS_CONTAINER_NAME:-${inst_id}-redis}"
    local pass="${REDIS_PASSWORD:-redis_secure_pass}"
    local port="${REDIS_PORT:-6379}"

    log_step "Verifying Redis instance [$inst_id] as Master..."

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_error "Redis container '$container' is not running."
        return 1
    fi

    # Ensure container is operating as master (remove any existing replicaof if present)
    if [ -n "$pass" ]; then
        docker exec -i "$container" redis-cli -a "$pass" REPLICAOF NO ONE >/dev/null 2>&1 || true
        docker exec -i "$container" redis-cli -a "$pass" CONFIG SET masterauth "$pass" >/dev/null 2>&1 || true
    else
        docker exec -i "$container" redis-cli REPLICAOF NO ONE >/dev/null 2>&1 || true
    fi

    log_success "Redis [$inst_id] is active as Master (Port: $port)."
    return 0
}

redis_bootstrap_replica() {
    local master_host="$1"
    local master_port="$2"
    local replica_container="$3"
    local replica_pass="$4"
    local master_pass="$5"

    log_step "Attaching Redis replica '$replica_container' to Master ($master_host:$master_port)..."

    # Configure masterauth and replicaof dynamically
    if [ -n "$replica_pass" ]; then
        if [ -n "$master_pass" ]; then
            docker exec -i "$replica_container" redis-cli -a "$replica_pass" CONFIG SET masterauth "$master_pass" >/dev/null 2>&1 || true
        fi
        docker exec -i "$replica_container" redis-cli -a "$replica_pass" REPLICAOF "$master_host" "$master_port" >/dev/null 2>&1
    else
        if [ -n "$master_pass" ]; then
            docker exec -i "$replica_container" redis-cli CONFIG SET masterauth "$master_pass" >/dev/null 2>&1 || true
        fi
        docker exec -i "$replica_container" redis-cli REPLICAOF "$master_host" "$master_port" >/dev/null 2>&1
    fi

    log_success "Redis replica successfully linked to Master."
    return 0
}

redis_get_lag() {
    local container="$1"
    local pass="${2:-}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "STOPPED"
        return
    fi

    local info_repl
    if [ -n "$pass" ]; then
        info_repl=$(docker exec "$container" redis-cli -a "$pass" info replication 2>/dev/null || true)
    else
        info_repl=$(docker exec "$container" redis-cli info replication 2>/dev/null || true)
    fi

    local role
    role=$(echo "$info_repl" | grep -E '^role:' | cut -d':' -f2 | tr -d '\r')

    if [ "$role" = "slave" ]; then
        local link_status last_io
        link_status=$(echo "$info_repl" | grep -E '^master_link_status:' | cut -d':' -f2 | tr -d '\r')
        last_io=$(echo "$info_repl" | grep -E '^master_last_io_seconds_ago:' | cut -d':' -f2 | tr -d '\r')
        echo "REPLICA|Link:$link_status ${last_io}s ago"
    elif [ "$role" = "master" ]; then
        local connected_slaves
        connected_slaves=$(echo "$info_repl" | grep -E '^connected_slaves:' | cut -d':' -f2 | tr -d '\r')
        echo "MASTER|${connected_slaves} connected replicas"
    else
        echo "UNKNOWN"
    fi
}
