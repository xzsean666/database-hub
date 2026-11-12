#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Environment Discovery, Inspection & Replica Derivation
# Supports multi-database instances and multi-environment stacks on single host
# ==============================================================================

# Scan directory for active .env files (local or remote)
scan_env_files() {
    local target_dir="${1:-$PROJECT_ROOT}"
    local files=()

    # Look for .env and *.env files, ignoring .example and backups
    while IFS= read -r f; do
        if [ -n "$f" ] && [[ "$f" != *".example"* ]] && [[ "$f" != *"backups"* ]] && [[ "$f" != *".git"* ]]; then
            files+=("$f")
        fi
    done < <(find "$target_dir" -maxdepth 3 -type f \( -name ".env" -o -name "*.env" \) | sort)

    for f in "${files[@]}"; do
        local rel_path="${f#$target_dir/}"
        local inst_id
        inst_id=$(grep -E '^[[:space:]]*INSTANCE_ID=' "$f" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "\r' || true)
        inst_id="${inst_id:-database-hub}"

        local role
        role=$(grep -E '^[[:space:]]*(ROLE|DBHUB_ROLE)=' "$f" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "\r' || true)
        role="${role:-standalone}"

        # Detect active DB services defined in this env
        local dbs=()
        if grep -qE '^[[:space:]]*POSTGRES_' "$f" 2>/dev/null; then
            local pg_port
            pg_port=$(grep -E '^[[:space:]]*POSTGRES_PORT=' "$f" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "\r' || true)
            dbs+=("Postgres:${pg_port:-5432}")
        fi
        if grep -qE '^[[:space:]]*MYSQL_' "$f" 2>/dev/null; then
            local my_port
            my_port=$(grep -E '^[[:space:]]*MYSQL_PORT=' "$f" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "\r' || true)
            dbs+=("MySQL:${my_port:-3306}")
        fi
        if grep -qE '^[[:space:]]*REDIS_' "$f" 2>/dev/null; then
            local r_port
            r_port=$(grep -E '^[[:space:]]*REDIS_PORT=' "$f" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "\r' || true)
            dbs+=("Redis:${r_port:-6379}")
        fi
        if grep -qE '^[[:space:]]*MONGO_' "$f" 2>/dev/null; then
            local mg_port
            mg_port=$(grep -E '^[[:space:]]*MONGO_PORT=' "$f" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "\r' || true)
            dbs+=("MongoDB:${mg_port:-27017}")
        fi

        local dbs_str
        dbs_str=$(IFS=, ; echo "${dbs[*]}")
        echo "${rel_path}|${inst_id}|${role}|${dbs_str:-All:DefaultPorts}"
    done
}

# Scan remote environments over SSH
scan_remote_env_files() {
    local raw_ssh="$1"
    local remote_dir="${2:-/opt/database-hub}"

    setup_ssh_wrapper "$raw_ssh"
    local remote_script='
target_dir="'"$remote_dir"'"
find "$target_dir" -maxdepth 3 -type f \( -name ".env" -o -name "*.env" \) 2>/dev/null | while IFS= read -r f; do
    if [ -n "$f" ] && [[ "$f" != *".example"* ]] && [[ "$f" != *"backups"* ]] && [[ "$f" != *".git"* ]]; then
        rel_path="${f#$target_dir/}"
        inst_id=$(grep -E "^[[:space:]]*INSTANCE_ID=" "$f" 2>/dev/null | head -n1 | cut -d"=" -f2- | tr -d " \"\r" || true)
        inst_id="${inst_id:-database-hub}"
        role=$(grep -E "^[[:space:]]*(ROLE|DBHUB_ROLE)=" "$f" 2>/dev/null | head -n1 | cut -d"=" -f2- | tr -d " \"\r" || true)
        role="${role:-standalone}"
        dbs=()
        if grep -qE "^[[:space:]]*POSTGRES_" "$f" 2>/dev/null; then
            pg_port=$(grep -E "^[[:space:]]*POSTGRES_PORT=" "$f" 2>/dev/null | head -n1 | cut -d"=" -f2- | tr -d " \"\r" || true)
            dbs+=("Postgres:${pg_port:-5432}")
        fi
        if grep -qE "^[[:space:]]*MYSQL_" "$f" 2>/dev/null; then
            my_port=$(grep -E "^[[:space:]]*MYSQL_PORT=" "$f" 2>/dev/null | head -n1 | cut -d"=" -f2- | tr -d " \"\r" || true)
            dbs+=("MySQL:${my_port:-3306}")
        fi
        if grep -qE "^[[:space:]]*REDIS_" "$f" 2>/dev/null; then
            r_port=$(grep -E "^[[:space:]]*REDIS_PORT=" "$f" 2>/dev/null | head -n1 | cut -d"=" -f2- | tr -d " \"\r" || true)
            dbs+=("Redis:${r_port:-6379}")
        fi
        if grep -qE "^[[:space:]]*MONGO_" "$f" 2>/dev/null; then
            mg_port=$(grep -E "^[[:space:]]*MONGO_PORT=" "$f" 2>/dev/null | head -n1 | cut -d"=" -f2- | tr -d " \"\r" || true)
            dbs+=("MongoDB:${mg_port:-27017}")
        fi
        dbs_str=$(IFS=, ; echo "${dbs[*]}")
        echo "${rel_path}|${inst_id}|${role}|${dbs_str:-All:DefaultPorts}"
    fi
done
'
    run_remote_cmd "$remote_script" || true
}

# Derive a replica .env configuration based on Master .env
derive_replica_env() {
    local master_env_file="$1"
    local replica_env_file="$2"
    local master_host="$3"
    local is_same_host="${4:-false}"
    local port_offset="${5:-10}"
    local max_rate="${6:-30M}"

    if [ ! -f "$master_env_file" ]; then
        echo "[ERROR] Master env file not found: $master_env_file" >&2
        return 1
    fi

    # Subshell to load master env without polluting parent scope
    (
        set -a
        # shellcheck disable=SC1090
        source "$master_env_file"
        set +a

        local m_inst="${INSTANCE_ID:-database-hub}"
        local r_inst="${m_inst}-replica"
        if [ "$is_same_host" != "true" ]; then
            # On remote host, can keep same or append replica
            r_inst="${m_inst}-replica"
        fi

        local pg_m_port="${POSTGRES_PORT:-5432}"
        local my_m_port="${MYSQL_PORT:-3306}"
        local rd_m_port="${REDIS_PORT:-6379}"
        local mg_m_port="${MONGO_PORT:-27017}"

        local pg_r_port="$pg_m_port"
        local my_r_port="$my_m_port"
        local rd_r_port="$rd_m_port"
        local mg_r_port="$mg_m_port"

        if [ "$is_same_host" = "true" ]; then
            pg_r_port=$((pg_m_port + port_offset))
            my_r_port=$((my_m_port + port_offset))
            rd_r_port=$((rd_m_port + port_offset))
            mg_r_port=$((mg_m_port + port_offset))
        fi

        local my_server_id=$(( ${MYSQL_SERVER_ID:-1} + 100 ))

        mkdir -p "$(dirname "$replica_env_file")"

        cat > "$replica_env_file" << EOF
# ==============================================================================
# Database Hub - Auto-Generated Replica Environment
# Derived from Master: $m_inst ($master_host)
# Created at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ==============================================================================

# Role & Cluster Topology
ROLE=replica
DBHUB_ROLE=replica
MASTER_HOST=${master_host}
MASTER_INSTANCE_ID=${m_inst}
REPLICATION_MAX_RATE=${max_rate}

# Instance Identification & Isolation
INSTANCE_ID=${r_inst}
COMPOSE_PROJECT_NAME=${r_inst}
TZ=${TZ:-UTC}
BIND_IP=0.0.0.0
DATA_DIR=./data/${r_inst}
DOCKER_NETWORK_NAME=${r_inst}-net

# ==============================================================================
# 1. PostgreSQL Replica Settings
# ==============================================================================
POSTGRES_IMAGE=${POSTGRES_IMAGE:-postgres:16-alpine}
POSTGRES_CONTAINER_NAME=${r_inst}-postgres
POSTGRES_PORT=${pg_r_port}
POSTGRES_MASTER_PORT=${pg_m_port}
POSTGRES_DATA_DIR=./data/${r_inst}/postgres
POSTGRES_DB=${POSTGRES_DB:-app_db}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres_secure_pass}
POSTGRES_ROLE=replica
POSTGRES_SHM_SIZE=${POSTGRES_SHM_SIZE:-1g}
POSTGRES_MAX_CONNECTIONS=${POSTGRES_MAX_CONNECTIONS:-200}
POSTGRES_SHARED_BUFFERS=${POSTGRES_SHARED_BUFFERS:-1GB}
POSTGRES_EFFECTIVE_CACHE_SIZE=${POSTGRES_EFFECTIVE_CACHE_SIZE:-3GB}

# ==============================================================================
# 2. MySQL Replica Settings
# ==============================================================================
MYSQL_IMAGE=${MYSQL_IMAGE:-mysql:8.0}
MYSQL_CONTAINER_NAME=${r_inst}-mysql
MYSQL_PORT=${my_r_port}
MYSQL_MASTER_PORT=${my_m_port}
MYSQL_DATA_DIR=./data/${r_inst}/mysql
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}
MYSQL_DATABASE=${MYSQL_DATABASE:-app_db}
MYSQL_USER=${MYSQL_USER:-app_user}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-mysql_user_secure_pass}
MYSQL_ROLE=replica
MYSQL_SERVER_ID=${my_server_id}
MYSQL_BUFFER_POOL_SIZE=${MYSQL_BUFFER_POOL_SIZE:-1G}
MYSQL_MAX_CONNECTIONS=${MYSQL_MAX_CONNECTIONS:-300}

# ==============================================================================
# 3. Redis Replica Settings
# ==============================================================================
REDIS_IMAGE=${REDIS_IMAGE:-redis:7.2-alpine}
REDIS_CONTAINER_NAME=${r_inst}-redis
REDIS_PORT=${rd_r_port}
REDIS_MASTER_HOST=${master_host}
REDIS_MASTER_PORT=${rd_m_port}
REDIS_DATA_DIR=./data/${r_inst}/redis
REDIS_PASSWORD=${REDIS_PASSWORD:-redis_secure_pass}
REDIS_MASTER_PASSWORD=${REDIS_PASSWORD:-redis_secure_pass}
REDIS_ROLE=replica
REDIS_MAX_MEMORY=${REDIS_MAX_MEMORY:-1gb}
REDIS_MAXMEMORY_POLICY=${REDIS_MAXMEMORY_POLICY:-allkeys-lru}

# ==============================================================================
# 4. MongoDB Replica Settings
# ==============================================================================
MONGO_IMAGE=${MONGO_IMAGE:-mongo:7.0}
MONGO_CONTAINER_NAME=${r_inst}-mongodb
MONGO_PORT=${mg_r_port}
MONGO_MASTER_PORT=${mg_m_port}
MONGO_DATA_DIR=./data/${r_inst}/mongodb
MONGO_INITDB_ROOT_USERNAME=${MONGO_INITDB_ROOT_USERNAME:-root}
MONGO_INITDB_ROOT_PASSWORD=${MONGO_INITDB_ROOT_PASSWORD:-mongo_root_secure_pass}
MONGO_INITDB_DATABASE=${MONGO_INITDB_DATABASE:-app_db}
MONGO_REPL_SET_NAME=${MONGO_REPL_SET_NAME:-rs_${m_inst}}
MONGO_ROLE=replica
MONGO_CACHE_SIZE_GB=${MONGO_CACHE_SIZE_GB:-2}

# ==============================================================================
# 5. Backup Settings for Replica Node
# ==============================================================================
AUTO_BACKUP_ENABLED=${AUTO_BACKUP_ENABLED:-true}
AUTO_BACKUP_SCHEDULE="${AUTO_BACKUP_SCHEDULE:-0 2 * * *}"
AUTO_BACKUP_RETENTION=${AUTO_BACKUP_RETENTION:-7}
BACKUP_DIR=./backups
BACKUP_COMPRESSION=${BACKUP_COMPRESSION:-zstd}
EOF
    )
    return 0
}
