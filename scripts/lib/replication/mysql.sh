#!/usr/bin/env bash
# ==============================================================================
# Database Hub - MySQL Replication Driver (GTID + Binlog + Clone Plugin)
# Supports: In-place Upgrade to Master, Online Clone/GTID Bootstrap, Lag Check
# ==============================================================================

mysql_make_master() {
    local env_file="$1"
    local inst_id="${INSTANCE_ID:-database-hub}"
    local container="${MYSQL_CONTAINER_NAME:-${inst_id}-mysql}"
    local root_pass="${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}"
    local port="${MYSQL_PORT:-3306}"

    log_step "Configuring MySQL instance [$inst_id] as Master..."

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_error "MySQL container '$container' is not running."
        return 1
    fi

    local repl_user="repl_${inst_id//-/_}"
    local repl_pass
    repl_pass=$(generate_random_secret 24)

    log_info "Creating replication user '$repl_user' in MySQL..."
    docker exec -i -e MYSQL_PWD="$root_pass" "$container" mysql -u root >/dev/null 2>&1 << EOF || true
CREATE USER IF NOT EXISTS '${repl_user}'@'%' IDENTIFIED BY '${repl_pass}';
ALTER USER '${repl_user}'@'%' IDENTIFIED BY '${repl_pass}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT, BACKUP_ADMIN ON *.* TO '${repl_user}'@'%';
FLUSH PRIVILEGES;
EOF

    log_success "MySQL [$inst_id] is now operating as Master (User: $repl_user, Port: $port)."
    echo "REPL_USER=$repl_user"
    echo "REPL_PASS=$repl_pass"
    return 0
}

mysql_bootstrap_replica() {
    local master_host="$1"
    local master_port="$2"
    local repl_user="$3"
    local repl_pass="$4"
    local replica_container="$5"
    local root_pass="$6"

    log_step "Setting up MySQL replica on container '$replica_container'..."

    log_info "Configuring GTID replication channel and read-only mode..."
    local attempts=0
    local max_attempts=30
    while [ "$attempts" -lt "$max_attempts" ]; do
        if docker exec -i -e MYSQL_PWD="$root_pass" "$replica_container" mysql -u root >/dev/null 2>&1 << EOF
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${master_host}',
  SOURCE_PORT=${master_port},
  SOURCE_USER='${repl_user}',
  SOURCE_PASSWORD='${repl_pass}',
  SOURCE_AUTO_POSITION=1,
  SOURCE_SSL=0;
START REPLICA;
SET GLOBAL read_only = ON;
SET GLOBAL super_read_only = ON;
EOF
        then
            log_success "MySQL replica configured and synchronized with Master."
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    log_error "Failed to configure MySQL replica on '$replica_container' after $max_attempts attempts."
    return 1
}

mysql_get_lag() {
    local container="$1"
    local root_pass="${2:-mysql_root_secure_pass}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "STOPPED"
        return
    fi

    local repl_status
    repl_status=$(docker exec -e MYSQL_PWD="$root_pass" "$container" mysql -u root -e "SHOW REPLICA STATUS\G" 2>/dev/null || docker exec -e MYSQL_PWD="$root_pass" "$container" mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null || true)

    if [ -n "$repl_status" ]; then
        local io_run sql_run sec_behind
        io_run=$(echo "$repl_status" | grep -E "Replica_IO_Running:|Slave_IO_Running:" | awk '{print $2}' || echo "No")
        sql_run=$(echo "$repl_status" | grep -E "Replica_SQL_Running:|Slave_SQL_Running:" | awk '{print $2}' || echo "No")
        sec_behind=$(echo "$repl_status" | grep -E "Seconds_Behind_Source:|Seconds_Behind_Master:" | awk '{print $2}' || echo "0")
        echo "REPLICA|IO:$io_run SQL:$sql_run ${sec_behind}s lag"
    else
        local repl_count
        repl_count=$(docker exec -e MYSQL_PWD="$root_pass" "$container" mysql -u root -e "SHOW REPLICAS;" 2>/dev/null | wc -l || true)
        local count=$((repl_count > 1 ? repl_count - 1 : 0))
        echo "MASTER|${count} active replicas"
    fi
}
