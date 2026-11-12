#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Replication Orchestrator
# Coordinates: In-place Master Promotion, Replica Bootstrapping & Lag Inspection
# Strictly scoped by .env file to support multiple databases/instances per host
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source modular libraries
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/cluster/network.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/cluster/metadata.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/cluster/env-manager.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/replication/common.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/replication/postgres.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/replication/mysql.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/replication/redis.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/replication/mongodb.sh"

ACTION=""
ENV_FILE=""
MASTER_ENV=""
MASTER_SSH=""
TARGET_DBS="all"
MAX_RATE="30M"
MASTER_HOST_OVERRIDE=""

show_help() {
    echo -e "${BOLD}Database Hub - Replication Management Engine${NC}

Usage:
  ./scripts/replication.sh <action> [options]

Actions:
  make-master        Upgrade an existing standalone database instance to Master
  deploy-replica     Deploy and bootstrap a replica from Master configuration
  status             Inspect replication status and lag for an instance
  scan               Scan and list active database environments on this host

Options:
  -e, --env <path>           Path to .env file for target instance
  -m, --master-env <path>    Path to Master's .env file (for replica deployment)
      --master-ssh <cmd>     SSH command to connect to Master server
      --master-host <ip>     Override Master IP address (auto-detected if omitted)
  -d, --db <databases>       Target databases: postgres, mysql, redis, mongodb, all (default: all)
      --max-rate <rate>      Bandwidth limit for initial sync (default: 30M)
  -h, --help                 Show this help message
"
}

# Parse CLI arguments
parse_args() {
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_help
        exit 0
    fi

    ACTION="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--env)
                ENV_FILE="$2"
                shift 2
                ;;
            -m|--master-env)
                MASTER_ENV="$2"
                shift 2
                ;;
            --master-ssh)
                MASTER_SSH="$2"
                shift 2
                ;;
            --master-host)
                MASTER_HOST_OVERRIDE="$2"
                shift 2
                ;;
            -d|--db)
                TARGET_DBS="$2"
                shift 2
                ;;
            --max-rate)
                MAX_RATE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# ==============================================================================
# Action: make-master
# Upgrades the database stack defined in $ENV_FILE to Master
# ==============================================================================
do_make_master() {
    load_env_file "$ENV_FILE" "$PROJECT_ROOT" || true
    local inst_id="${INSTANCE_ID:-database-hub}"

    log_step "Upgrading Database Hub instance [$inst_id] to Master..."
    log_info "Configuration source: $ENV_FILE_LOADED"

    local detected_ip
    detected_ip=$(detect_primary_ip "")
    local master_host="${MASTER_HOST_OVERRIDE:-$detected_ip}"
    log_info "Master advertisement address: $master_host"

    local pg_repl_user="" pg_repl_pass=""
    local my_repl_user="" my_repl_pass=""

    # Load existing metadata if available to preserve prior credentials
    local existing_meta=""
    existing_meta=$(load_metadata "$inst_id" "$PROJECT_ROOT" || true)
    if [ -n "$existing_meta" ]; then
        pg_repl_user=$(read_json_val "$existing_meta" ".databases.postgres.repl_user")
        pg_repl_pass=$(read_json_val "$existing_meta" ".databases.postgres.repl_pass")
        my_repl_user=$(read_json_val "$existing_meta" ".databases.mysql.repl_user")
        my_repl_pass=$(read_json_val "$existing_meta" ".databases.mysql.repl_pass")
    fi

    # 1. PostgreSQL
    if [[ "$TARGET_DBS" == "all" ]] || [[ "$TARGET_DBS" == *"postgres"* ]]; then
        local pg_ctr="${POSTGRES_CONTAINER_NAME:-${inst_id}-postgres}"
        if docker ps --format '{{.Names}}' | grep -q "^${pg_ctr}$"; then
            local pg_out
            pg_out=$(postgres_make_master "$ENV_FILE_LOADED")
            echo "$pg_out" | grep -vE '^(REPL_USER=|REPL_PASS=)' || true
            pg_repl_user=$(echo "$pg_out" | grep 'REPL_USER=' | cut -d'=' -f2-)
            pg_repl_pass=$(echo "$pg_out" | grep 'REPL_PASS=' | cut -d'=' -f2-)
        fi
    fi

    # 2. MySQL
    if [[ "$TARGET_DBS" == "all" ]] || [[ "$TARGET_DBS" == *"mysql"* ]]; then
        local my_ctr="${MYSQL_CONTAINER_NAME:-${inst_id}-mysql}"
        if docker ps --format '{{.Names}}' | grep -q "^${my_ctr}$"; then
            local my_out
            my_out=$(mysql_make_master "$ENV_FILE_LOADED")
            echo "$my_out" | grep -vE '^(REPL_USER=|REPL_PASS=)' || true
            my_repl_user=$(echo "$my_out" | grep 'REPL_USER=' | cut -d'=' -f2-)
            my_repl_pass=$(echo "$my_out" | grep 'REPL_PASS=' | cut -d'=' -f2-)
        fi
    fi

    # 3. Redis
    if [[ "$TARGET_DBS" == "all" ]] || [[ "$TARGET_DBS" == *"redis"* ]]; then
        local rd_ctr="${REDIS_CONTAINER_NAME:-${inst_id}-redis}"
        if docker ps --format '{{.Names}}' | grep -q "^${rd_ctr}$"; then
            redis_make_master "$ENV_FILE_LOADED"
        fi
    fi

    # 4. MongoDB
    if [[ "$TARGET_DBS" == "all" ]] || [[ "$TARGET_DBS" == *"mongodb"* ]] || [[ "$TARGET_DBS" == *"mongo"* ]]; then
        local mg_ctr="${MONGO_CONTAINER_NAME:-${inst_id}-mongodb}"
        if docker ps --format '{{.Names}}' | grep -q "^${mg_ctr}$"; then
            mongodb_make_master "$ENV_FILE_LOADED" "$master_host"
        fi
    fi

    # 5. Persist instance metadata
    local meta_json="{
  \"instance_id\": \"$inst_id\",
  \"role\": \"master\",
  \"master_host\": \"$master_host\",
  \"created_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",
  \"databases\": {
    \"postgres\": {
      \"port\": ${POSTGRES_PORT:-5432},
      \"db\": \"${POSTGRES_DB:-app_db}\",
      \"repl_user\": \"$pg_repl_user\",
      \"repl_pass\": \"$pg_repl_pass\"
    },
    \"mysql\": {
      \"port\": ${MYSQL_PORT:-3306},
      \"db\": \"${MYSQL_DATABASE:-app_db}\",
      \"server_id\": ${MYSQL_SERVER_ID:-1},
      \"repl_user\": \"$my_repl_user\",
      \"repl_pass\": \"$my_repl_pass\"
    },
    \"redis\": {
      \"port\": ${REDIS_PORT:-6379},
      \"has_auth\": $( [ -n "${REDIS_PASSWORD:-}" ] && echo "true" || echo "false" )
    },
    \"mongodb\": {
      \"port\": ${MONGO_PORT:-27017},
      \"repl_set_name\": \"${MONGO_REPL_SET_NAME:-rs_${inst_id}}\"
    }
  }
}"
    save_metadata "$inst_id" "$meta_json" "$PROJECT_ROOT"
    log_success "Instance [$inst_id] successfully registered as Master in metadata."
}

# ==============================================================================
# Action: deploy-replica
# Bootstraps and starts a replica based on Master's configuration
# ==============================================================================
do_deploy_replica() {
    local replica_env="${ENV_FILE:-.env}"

    # Auto-derive replica environment if target env file doesn't exist yet but master env is given
    if [ ! -f "$replica_env" ] && [ -n "$MASTER_ENV" ]; then
        log_info "Replica env '$replica_env' does not exist. Deriving from Master env '$MASTER_ENV'..."
        local is_same="true"
        if [ -n "$MASTER_SSH" ]; then is_same="false"; fi
        local m_host="${MASTER_HOST_OVERRIDE:-}"
        if [ -z "$m_host" ]; then
            m_host=$(detect_primary_ip)
        fi
        derive_replica_env "$MASTER_ENV" "$replica_env" "$m_host" "$is_same" 10 "$MAX_RATE"
    fi

    load_env_file "$replica_env" "$PROJECT_ROOT" || true

    local r_inst="${INSTANCE_ID:-database-hub-replica}"
    local m_host="${MASTER_HOST:-127.0.0.1}"
    local m_inst="${MASTER_INSTANCE_ID:-database-hub}"

    log_step "Bootstrapping Replica instance [$r_inst] tracking Master [$m_inst @ $m_host]..."

    # Retrieve Master metadata to read credentials
    local master_meta=""
    if [ -n "$MASTER_SSH" ]; then
        log_info "Fetching Master metadata over SSH ($MASTER_SSH)..."
        master_meta=$(fetch_remote_metadata "$MASTER_SSH" "/opt/database-hub" "$m_inst" || true)
    else
        master_meta=$(load_metadata "$m_inst" "$PROJECT_ROOT" || true)
    fi

    # 1. Bootstrap PostgreSQL if selected
    if [[ "$TARGET_DBS" == "all" ]] || [[ "$TARGET_DBS" == *"postgres"* ]]; then
        local pg_m_port="${POSTGRES_MASTER_PORT:-${POSTGRES_PORT:-5432}}"
        local pg_r_data="${POSTGRES_DATA_DIR:-/app/database/postgres/${POSTGRES_CONTAINER_NAME:-${r_inst}-postgres}}"
        local pg_repl_user="repl_${m_inst//-/_}"
        local pg_repl_pass=""

        if [ -n "$master_meta" ]; then
            pg_repl_pass=$(read_json_val "$master_meta" ".databases.postgres.repl_pass")
            local meta_user
            meta_user=$(read_json_val "$master_meta" ".databases.postgres.repl_user")
            if [ -n "$meta_user" ]; then pg_repl_user="$meta_user"; fi
        fi

        if [ -z "$pg_repl_pass" ]; then
            log_warn "PostgreSQL replication password not found in metadata. Attempting prompt..."
            read -rsp "Enter PostgreSQL replication password for user '$pg_repl_user': " pg_repl_pass
            echo ""
        fi

        # Pre-flight network check
        log_info "Verifying network connectivity to PostgreSQL Master ($m_host:$pg_m_port)..."
        if ! test_tcp_port "$m_host" "$pg_m_port" 5; then
            log_error "Cannot reach PostgreSQL Master at $m_host:$pg_m_port! Check firewall/security groups."
            exit 1
        fi

        # Execute throttled physical base backup
        postgres_bootstrap_replica "$m_host" "$pg_m_port" "$pg_repl_user" "$pg_repl_pass" "$pg_r_data" "$MAX_RATE" "${POSTGRES_IMAGE:-postgres:18-alpine}"
    fi

    # 2. Launch Replica Containers via Docker Compose
    log_info "Launching replica containers for [$r_inst]..."
    local profile_flags=""
    if [ "$TARGET_DBS" = "all" ]; then
        profile_flags="--profile all"
    else
        IFS=',' read -ra ADDR <<< "$TARGET_DBS"
        for db in "${ADDR[@]}"; do
            db=$(echo "$db" | xargs)
            case "$db" in
                postgres|postgresql) profile_flags="$profile_flags --profile postgres" ;;
                mysql)               profile_flags="$profile_flags --profile mysql" ;;
                mongo|mongodb)       profile_flags="$profile_flags --profile mongodb" ;;
                redis)               profile_flags="$profile_flags --profile redis" ;;
                all)                 profile_flags="--profile all"; break ;;
            esac
        done
    fi

    # Ensure MongoDB keyfile exists for container mounting
    local keyfile="$PROJECT_ROOT/configs/mongodb/keys/mongo-keyfile"
    if [ ! -f "$keyfile" ]; then
        mkdir -p "$(dirname "$keyfile")"
        openssl rand -base64 756 > "$keyfile" 2>/dev/null || head -c 512 /dev/urandom | base64 > "$keyfile"
        chown 999:999 "$keyfile" 2>/dev/null || true
        chmod 400 "$keyfile" 2>/dev/null || true
    fi

    local compose_cmd="docker compose -p $r_inst --env-file $replica_env $profile_flags up -d"
    eval "$compose_cmd"

    # Wait for containers to boot
    sleep 4

    # 3. Post-boot replica configuration for MySQL, Redis, MongoDB
    if [[ "$TARGET_DBS" == "all" ]] || [[ "$TARGET_DBS" == *"mysql"* ]]; then
        local my_ctr="${MYSQL_CONTAINER_NAME:-${r_inst}-mysql}"
        local my_m_port="${MYSQL_MASTER_PORT:-${MYSQL_PORT:-3306}}"
        local my_repl_user="repl_${m_inst//-/_}"
        local my_repl_pass=""

        if [ -n "$master_meta" ]; then
            my_repl_pass=$(read_json_val "$master_meta" ".databases.mysql.repl_pass")
            local meta_my_user
            meta_my_user=$(read_json_val "$master_meta" ".databases.mysql.repl_user")
            if [ -n "$meta_my_user" ]; then my_repl_user="$meta_my_user"; fi
        fi

        if docker ps --format '{{.Names}}' | grep -q "^${my_ctr}$"; then
            wait_container_responsive "$my_ctr" "mysqladmin ping -u root -p${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}" 30
            mysql_bootstrap_replica "$m_host" "$my_m_port" "$my_repl_user" "$my_repl_pass" "$my_ctr" "${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}"
        fi
    fi

    if [[ "$TARGET_DBS" == "all" ]] || [[ "$TARGET_DBS" == *"redis"* ]]; then
        local rd_ctr="${REDIS_CONTAINER_NAME:-${r_inst}-redis}"
        local rd_m_port="${REDIS_MASTER_PORT:-${REDIS_PORT:-6379}}"
        if docker ps --format '{{.Names}}' | grep -q "^${rd_ctr}$"; then
            redis_bootstrap_replica "$m_host" "$rd_m_port" "$rd_ctr" "${REDIS_PASSWORD:-}" "${REDIS_MASTER_PASSWORD:-${REDIS_PASSWORD:-}}"
        fi
    fi

    if [[ "$TARGET_DBS" == "all" ]] || [[ "$TARGET_DBS" == *"mongodb"* ]] || [[ "$TARGET_DBS" == *"mongo"* ]]; then
        local mg_ctr="${MONGO_CONTAINER_NAME:-${r_inst}-mongodb}"
        local mg_m_port="${MONGO_MASTER_PORT:-${MONGO_PORT:-27017}}"
        local slave_host
        slave_host=$(detect_primary_ip "$m_host")
        if [ -n "$MASTER_SSH" ]; then
            run_remote_cmd "cd /opt/database-hub && bash scripts/replication.sh register-mongo-member --env .env --slave-host '$slave_host' --slave-port '${MONGO_PORT:-27017}'" || true
        else
            local m_ctr="${m_inst}-mongodb"
            if docker ps --format '{{.Names}}' | grep -q "^${m_ctr}$"; then
                mongodb_bootstrap_replica "$m_host" "$mg_m_port" "$m_ctr" "${MONGO_INITDB_ROOT_USERNAME:-root}" "${MONGO_INITDB_ROOT_PASSWORD:-mongo_root_pass_2026}" "$slave_host" "${MONGO_PORT:-27017}"
            fi
        fi
    fi

    log_success "Replica instance [$r_inst] deployed and streaming from Master [$m_host]!"
}

# ==============================================================================
# Action: status
# Prints the status, role, and sync lag of the target environment
# ==============================================================================
do_status() {
    load_env_file "$ENV_FILE" "$PROJECT_ROOT" || true
    local inst_id="${INSTANCE_ID:-database-hub}"
    local role="${ROLE:-${DBHUB_ROLE:-standalone}}"

    echo -e "${BLUE}================================================================================${NC}"
    echo -e "${BOLD}Database Hub - Replication & Sync Status Overview${NC}"
    echo -e "Instance: ${BOLD}$inst_id${NC} | Role: ${BOLD}$role${NC} | Env: $ENV_FILE_LOADED"
    echo -e "${BLUE}================================================================================${NC}"
    printf "%-14s %-12s %-25s %-25s\n" "ENGINE" "ROLE" "CONTAINER" "REPLICATION / LAG STATUS"
    echo "--------------------------------------------------------------------------------"

    # 1. PostgreSQL
    local pg_ctr="${POSTGRES_CONTAINER_NAME:-${inst_id}-postgres}"
    local pg_status
    pg_status=$(postgres_get_lag "$pg_ctr" "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-app_db}")
    local pg_role="${pg_status%%|*}"
    local pg_info="${pg_status#*|}"
    printf "%-14s %-12s %-25s %-25s\n" "PostgreSQL" "$pg_role" "$pg_ctr" "$pg_info"

    # 2. MySQL
    local my_ctr="${MYSQL_CONTAINER_NAME:-${inst_id}-mysql}"
    local my_status
    my_status=$(mysql_get_lag "$my_ctr" "${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}")
    local my_role="${my_status%%|*}"
    local my_info="${my_status#*|}"
    printf "%-14s %-12s %-25s %-25s\n" "MySQL" "$my_role" "$my_ctr" "$my_info"

    # 3. Redis
    local rd_ctr="${REDIS_CONTAINER_NAME:-${inst_id}-redis}"
    local rd_status
    rd_status=$(redis_get_lag "$rd_ctr" "${REDIS_PASSWORD:-}")
    local rd_role="${rd_status%%|*}"
    local rd_info="${rd_status#*|}"
    printf "%-14s %-12s %-25s %-25s\n" "Redis" "$rd_role" "$rd_ctr" "$rd_info"

    # 4. MongoDB
    local mg_ctr="${MONGO_CONTAINER_NAME:-${inst_id}-mongodb}"
    local mg_status
    mg_status=$(mongodb_get_lag "$mg_ctr" "${MONGO_INITDB_ROOT_USERNAME:-root}" "${MONGO_INITDB_ROOT_PASSWORD:-mongo_root_secure_pass}")
    local mg_role="${mg_status%%|*}"
    local mg_info="${mg_status#*|}"
    printf "%-14s %-12s %-25s %-25s\n" "MongoDB" "$mg_role" "$mg_ctr" "$mg_info"

    echo -e "${BLUE}================================================================================${NC}"
}

# ==============================================================================
# Action: scan
# Scans and displays active database environments on this host
# ==============================================================================
do_scan() {
    echo -e "${BOLD}Scanning database environments in: $PROJECT_ROOT${NC}\n"
    printf "%-30s %-18s %-12s %-30s\n" "ENV FILE" "INSTANCE ID" "ROLE" "DATABASES / PORTS"
    echo "----------------------------------------------------------------------------------------------"
    while IFS='|' read -r rel_path inst_id role dbs; do
        if [ -n "$rel_path" ]; then
            printf "%-30s %-18s %-12s %-30s\n" "$rel_path" "$inst_id" "$role" "$dbs"
        fi
    done < <(scan_env_files "$PROJECT_ROOT")
    echo ""
}

# ==============================================================================
# Main Entrypoint
# ==============================================================================
main() {
    parse_args "$@"

    case "$ACTION" in
        make-master)
            do_make_master
            ;;
        deploy-replica)
            do_deploy_replica
            ;;
        status|repl-status)
            do_status
            ;;
        scan)
            do_scan
            ;;
        *)
            log_error "Unknown action: $ACTION"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
