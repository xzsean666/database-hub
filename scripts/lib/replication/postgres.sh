#!/usr/bin/env bash
# ==============================================================================
# Database Hub - PostgreSQL Replication Driver
# Supports: In-place Upgrade to Master, Gradual Throttled Bootstrap, Lag Check
# ==============================================================================

postgres_make_master() {
    local env_file="$1"
    local inst_id="${INSTANCE_ID:-database-hub}"
    local container="${POSTGRES_CONTAINER_NAME:-${inst_id}-postgres}"
    local user="${POSTGRES_USER:-postgres}"
    local db="${POSTGRES_DB:-app_db}"
    local port="${POSTGRES_PORT:-5432}"

    log_step "Configuring PostgreSQL instance [$inst_id] as Master..."

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_error "PostgreSQL container '$container' is not running."
        return 1
    fi

    # 1. Setup replication user
    local repl_user="repl_${inst_id//-/_}"
    local repl_pass
    repl_pass=$(generate_random_secret 24)

    log_info "Creating replication role '$repl_user' in PostgreSQL..."
    docker exec -i "$container" psql -U "$user" -d "$db" >/dev/null 2>&1 << EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$repl_user') THEN
    CREATE ROLE $repl_user WITH REPLICATION LOGIN PASSWORD '$repl_pass';
  ELSE
    ALTER ROLE $repl_user WITH REPLICATION LOGIN PASSWORD '$repl_pass';
  END IF;
END
\$\$;
EOF

    # 2. Update pg_hba.conf to allow replication connections
    log_info "Configuring pg_hba.conf replication authorization..."
    docker exec -i "$container" sh -c "
        PGDATA=\"/var/lib/postgresql/data\"
        if ! grep -q \"$repl_user\" \"\$PGDATA/pg_hba.conf\" 2>/dev/null; then
            echo \"host replication $repl_user 0.0.0.0/0 scram-sha-256\" >> \"\$PGDATA/pg_hba.conf\"
            echo \"host replication $repl_user 0.0.0.0/0 md5\" >> \"\$PGDATA/pg_hba.conf\"
        fi
    "

    # 3. Reload configuration without downtime
    log_info "Reloading PostgreSQL configuration..."
    docker exec -i "$container" psql -U "$user" -d "$db" -c "SELECT pg_reload_conf();" >/dev/null 2>&1

    log_success "PostgreSQL [$inst_id] is now operating as Master (User: $repl_user, Port: $port)."
    echo "REPL_USER=$repl_user"
    echo "REPL_PASS=$repl_pass"
    return 0
}

postgres_bootstrap_replica() {
    local master_host="$1"
    local master_port="$2"
    local repl_user="$3"
    local repl_pass="$4"
    local replica_data_dir="$5"
    local max_rate="${6:-30M}"
    local image="${7:-postgres:16-alpine}"

    log_step "Bootstrapping PostgreSQL replica data from Master ($master_host:$master_port)..."
    log_info "Bandwidth limit: ${max_rate} (Zero impact on Master workload)"

    # Ensure host directory is empty for clean pg_basebackup
    if [ -d "$replica_data_dir" ] && [ "$(ls -A "$replica_data_dir" 2>/dev/null)" ]; then
        log_warn "Target data directory '$replica_data_dir' is not empty. Creating safety backup..."
        local bk_dir="${replica_data_dir}_backup_$(date +%s)"
        mv "$replica_data_dir" "$bk_dir"
        log_info "Existing data backed up to: $bk_dir"
    fi
    mkdir -p "$replica_data_dir"
    chmod 700 "$replica_data_dir"
    local abs_data_dir
    abs_data_dir="$(cd "$replica_data_dir" && pwd)"

    # Run pg_basebackup in container directly mounting target directory
    log_info "Streaming base snapshot from Master..."
    if ! docker run --rm --net=host \
        -e PGPASSWORD="$repl_pass" \
        -v "$abs_data_dir:/var/lib/postgresql/data" \
        "$image" \
        pg_basebackup \
            -h "$master_host" \
            -p "$master_port" \
            -U "$repl_user" \
            -D /var/lib/postgresql/data \
            -Fp -Xs -P -R \
            --max-rate="$max_rate"; then
        log_error "pg_basebackup failed. Check master connection, port and replication credentials."
        return 1
    fi

    log_success "Base backup complete! Standby signal and replication configs written."
    return 0
}

postgres_get_lag() {
    local container="$1"
    local user="${2:-postgres}"
    local db="${3:-app_db}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "STOPPED"
        return
    fi

    # Check if in recovery (Replica / Standby)
    local is_replica
    is_replica=$(docker exec "$container" psql -U "$user" -d "$db" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

    if [ "$is_replica" = "t" ]; then
        local lag_seconds
        lag_seconds=$(docker exec "$container" psql -U "$user" -d "$db" -tAc "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int, 0);" 2>/dev/null || echo "0")
        echo "REPLICA|${lag_seconds}s lag"
    elif [ "$is_replica" = "f" ]; then
        local count_replicas
        count_replicas=$(docker exec "$container" psql -U "$user" -d "$db" -tAc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
        echo "MASTER|${count_replicas} active replicas"
    else
        echo "UNKNOWN"
    fi
}
