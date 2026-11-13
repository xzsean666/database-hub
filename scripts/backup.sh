#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Backup Engine (Extreme Compression & Retention)
# Supports PostgreSQL, MySQL, MongoDB, Redis
# Isolated per INSTANCE_ID so multiple database stacks coexist without conflicts
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared libraries
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/scheduler.sh"

# Default settings
DEFAULT_ENV_FILE="$PROJECT_ROOT/.env"
ENV_FILE="${ENV_FILE:-$DEFAULT_ENV_FILE}"

# Parse optional --env flag passed to backup.sh
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

load_env_file "$ENV_FILE" "$PROJECT_ROOT" || true

INSTANCE_ID="${INSTANCE_ID:-database-hub}"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/backups}"
mkdir -p "$BACKUP_DIR"

AUTO_BACKUP_RETENTION="${AUTO_BACKUP_RETENTION:-7}"
BACKUP_COMPRESSION="${BACKUP_COMPRESSION:-zstd}"

# ==============================================================================
# Database Backup Workers
# ==============================================================================

backup_postgres() {
    local inst_id="${INSTANCE_ID:-database-hub}"
    local container="${POSTGRES_CONTAINER_NAME:-${inst_id}-postgres}"
    local user="${POSTGRES_USER:-postgres}"
    local db="${POSTGRES_DB:-app_db}"
    local port="${POSTGRES_PORT:-5432}"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_warn "PostgreSQL container '$container' (port $port) is not running. Skipping."
        return 0
    fi

    local compressor
    compressor=$(detect_compressor "$BACKUP_COMPRESSION")
    local ext
    ext=$(get_archive_extension "$compressor")
    local outfile="$BACKUP_DIR/postgres_${inst_id}_${db}_${timestamp}.sql.${ext}"

    log_info "Backing up PostgreSQL [$inst_id / $db] (port $port) with extreme compression ($compressor)..."
    local start_time
    start_time=$(date +%s)

    if docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" "$container" pg_dump -U "$user" -d "$db" --clean --if-exists --create | $compressor > "$outfile"; then
        if [ -s "$outfile" ]; then
            sha256sum "$outfile" | awk '{print $1}' > "${outfile}.sha256"
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local size
            size=$(du -h "$outfile" | cut -f1)
            log_success "PostgreSQL backup completed: $(basename "$outfile") (Size: $size, Time: ${duration}s)"
        else
            rm -f "$outfile"
            log_error "PostgreSQL backup resulted in empty file."
            return 1
        fi
    else
        rm -f "$outfile"
        log_error "PostgreSQL dump command failed."
        return 1
    fi
}

backup_mysql() {
    local inst_id="${INSTANCE_ID:-database-hub}"
    local container="${MYSQL_CONTAINER_NAME:-${inst_id}-mysql}"
    local root_pass="${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}"
    local db="${MYSQL_DATABASE:-app_db}"
    local port="${MYSQL_PORT:-3306}"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_warn "MySQL container '$container' (port $port) is not running. Skipping."
        return 0
    fi

    local compressor
    compressor=$(detect_compressor "$BACKUP_COMPRESSION")
    local ext
    ext=$(get_archive_extension "$compressor")
    local outfile="$BACKUP_DIR/mysql_${inst_id}_${db}_${timestamp}.sql.${ext}"

    log_info "Backing up MySQL [$inst_id / $db] (port $port) with extreme compression ($compressor)..."
    local start_time
    start_time=$(date +%s)

    if docker exec -e MYSQL_PWD="$root_pass" "$container" mysqldump -u root \
        --databases "$db" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --add-drop-database \
        --add-drop-table 2>/dev/null | $compressor > "$outfile"; then
        if [ -s "$outfile" ]; then
            sha256sum "$outfile" | awk '{print $1}' > "${outfile}.sha256"
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local size
            size=$(du -h "$outfile" | cut -f1)
            log_success "MySQL backup completed: $(basename "$outfile") (Size: $size, Time: ${duration}s)"
        else
            rm -f "$outfile"
            log_error "MySQL backup resulted in empty file."
            return 1
        fi
    else
        rm -f "$outfile"
        log_error "MySQL dump command failed."
        return 1
    fi
}

backup_mongodb() {
    local inst_id="${INSTANCE_ID:-database-hub}"
    local container="${MONGO_CONTAINER_NAME:-${inst_id}-mongodb}"
    local user="${MONGO_INITDB_ROOT_USERNAME:-root}"
    local pass="${MONGO_INITDB_ROOT_PASSWORD:-mongo_root_secure_pass}"
    local db="${MONGO_INITDB_DATABASE:-app_db}"
    local port="${MONGO_PORT:-27017}"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_warn "MongoDB container '$container' (port $port) is not running. Skipping."
        return 0
    fi

    local compressor
    compressor=$(detect_compressor "$BACKUP_COMPRESSION")
    local ext
    ext=$(get_archive_extension "$compressor")
    local outfile="$BACKUP_DIR/mongodb_${inst_id}_${db}_${timestamp}.archive.${ext}"

    log_info "Backing up MongoDB [$inst_id / $db] (port $port) with extreme compression ($compressor)..."
    local start_time
    start_time=$(date +%s)

    if docker exec "$container" mongodump \
        --username "$user" \
        --password "$pass" \
        --authenticationDatabase admin \
        --db "$db" \
        --archive 2>/dev/null | $compressor > "$outfile"; then
        if [ -s "$outfile" ]; then
            sha256sum "$outfile" | awk '{print $1}' > "${outfile}.sha256"
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local size
            size=$(du -h "$outfile" | cut -f1)
            log_success "MongoDB backup completed: $(basename "$outfile") (Size: $size, Time: ${duration}s)"
        else
            rm -f "$outfile"
            log_error "MongoDB backup resulted in empty file."
            return 1
        fi
    else
        rm -f "$outfile"
        log_error "MongoDB dump command failed."
        return 1
    fi
}

backup_redis() {
    local inst_id="${INSTANCE_ID:-database-hub}"
    local container="${REDIS_CONTAINER_NAME:-${inst_id}-redis}"
    local pass="${REDIS_PASSWORD:-}"
    local port="${REDIS_PORT:-6379}"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_warn "Redis container '$container' (port $port) is not running. Skipping."
        return 0
    fi

    local compressor
    compressor=$(detect_compressor "$BACKUP_COMPRESSION")
    local ext
    ext=$(get_archive_extension "$compressor")
    local outfile="$BACKUP_DIR/redis_${inst_id}_${timestamp}.tar.${ext}"

    local redis_cli_base=(docker exec)
    if [ -n "$pass" ]; then
        redis_cli_base+=(-e "REDISCLI_AUTH=$pass")
    fi
    redis_cli_base+=("$container" redis-cli)

    log_info "Triggering Redis [$inst_id] (port $port) BGSAVE and awaiting completion..."
    local start_time
    start_time=$(date +%s)

    local bgsave_out
    bgsave_out=$("${redis_cli_base[@]}" bgsave 2>&1 || true)
    log_info "Redis bgsave response: $bgsave_out"

    # Wait for bgsave to finish (poll up to 60 seconds)
    local wait_sec=0
    while [ "$wait_sec" -lt 60 ]; do
        local in_progress
        in_progress=$("${redis_cli_base[@]}" info persistence 2>/dev/null | grep -E '^rdb_bgsave_in_progress:' | cut -d':' -f2 | tr -d '\r' || echo "0")
        if [ "$in_progress" = "0" ]; then
            break
        fi
        sleep 1
        wait_sec=$((wait_sec + 1))
    done

    local last_status
    last_status=$("${redis_cli_base[@]}" info persistence 2>/dev/null | grep -E '^rdb_last_bgsave_status:' | cut -d':' -f2 | tr -d '\r' || echo "ok")
    if [ "$last_status" != "ok" ]; then
        log_error "Redis bgsave reported non-ok status: $last_status"
        return 1
    fi

    if docker exec "$container" tar -cf - -C /data . 2>/dev/null | $compressor > "$outfile"; then
        if [ -s "$outfile" ]; then
            sha256sum "$outfile" | awk '{print $1}' > "${outfile}.sha256"
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local size
            size=$(du -h "$outfile" | cut -f1)
            log_success "Redis backup completed: $(basename "$outfile") (Size: $size, Time: ${duration}s)"
        else
            rm -f "$outfile"
            log_error "Redis backup resulted in empty file."
            return 1
        fi
    else
        rm -f "$outfile"
        log_error "Redis backup command failed."
        return 1
    fi
}

# ==============================================================================
# Retention & Pruning Engine (Per INSTANCE_ID)
# ==============================================================================
prune_backups() {
    local max_keep="${1:-$AUTO_BACKUP_RETENTION}"
    local inst_id="${INSTANCE_ID:-database-hub}"
    log_info "Checking retention policy for [$inst_id] (max keep: $max_keep backups per database)..."

    local db_prefixes=("postgres" "mysql" "mongodb" "redis")
    local total_pruned=0

    for prefix in "${db_prefixes[@]}"; do
        local files=()
        # Find matching backup files strictly for this specific INSTANCE_ID
        while IFS= read -r file; do
            [ -n "$file" ] && files+=("$file")
        done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${prefix}_${inst_id}_*" ! -name "*.sha256" | sort -r)

        # Fallback only if inst_id is "database-hub" (legacy files without inst_id in name)
        if [ "$inst_id" = "database-hub" ]; then
            while IFS= read -r file; do
                if [ -n "$file" ]; then
                    local bname
                    bname=$(basename "$file")
                    if [[ "$bname" =~ ^${prefix}_[0-9]{8}_[0-9]{6}\. ]]; then
                        files+=("$file")
                    fi
                fi
            done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${prefix}_*" ! -name "*.sha256" | sort -r)
        fi

        local count=${#files[@]}
        if [ "$count" -gt "$max_keep" ]; then
            for ((i = max_keep; i < count; i++)); do
                local old_file="${files[$i]}"
                rm -f "$old_file" "${old_file}.sha256"
                log_warn "[Pruned] Removed old backup: $(basename "$old_file")"
                total_pruned=$((total_pruned + 1))
            done
        fi
    done

    if [ "$total_pruned" -eq 0 ]; then
        log_info "No old backups needed pruning for [$inst_id]."
    else
        log_success "Retention pruning finished: cleaned up $total_pruned older backup(s) for [$inst_id]."
    fi
}

# ==============================================================================
# List Available Backups
# ==============================================================================
list_backups() {
    local format="${1:-table}"
    local filter_inst="${2:-}"

    if [ ! -d "$BACKUP_DIR" ]; then
        echo "No backups directory found at $BACKUP_DIR"
        return 0
    fi

    local backup_files=()
    while IFS= read -r f; do
        [ -n "$f" ] && backup_files+=("$f")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.zst" -o -name "*.xz" -o -name "*.gz" \) ! -name "*.sha256" | sort -r)

    if [ ${#backup_files[@]} -eq 0 ]; then
        if [ "$format" = "table" ]; then
            echo -e "${YELLOW}No existing backup files found in $BACKUP_DIR${NC}"
        fi
        return 0
    fi

    if [ "$format" = "table" ]; then
        printf "%-4s %-14s %-12s %-20s %-10s %s\n" "ID" "INSTANCE" "DATABASE" "CREATED AT" "SIZE" "FILENAME"
        printf "%-4s %-14s %-12s %-20s %-10s %s\n" "----" "--------------" "------------" "--------------------" "----------" "----------------------------------------"
    fi

    local id=1
    for f in "${backup_files[@]}"; do
        local fname
        fname=$(basename "$f")
        local db_type="unknown"
        case "$fname" in
            postgres_*) db_type="postgres" ;;
            mysql_*)    db_type="mysql" ;;
            mongodb_*)  db_type="mongodb" ;;
            redis_*)    db_type="redis" ;;
        esac

        # Extract INSTANCE_ID from filename: <db>_<inst>_...
        local extracted_inst="default"
        if [[ "$fname" =~ ^([^_]+)_([^_]+)_ ]]; then
            extracted_inst="${BASH_REMATCH[2]}"
        fi

        if [ -n "$filter_inst" ] && [ "$extracted_inst" != "$filter_inst" ] && [ "$filter_inst" != "all" ]; then
            continue
        fi

        local fdate
        fdate=$(date -r "$f" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d'.' -f1 || echo "Unknown")
        local fsize
        fsize=$(du -h "$f" | cut -f1)

        if [ "$format" = "table" ]; then
            printf "%-4s %-14s %-12s %-20s %-10s %s\n" "$id" "$extracted_inst" "$db_type" "$fdate" "$fsize" "$fname"
        else
            echo "$id|$extracted_inst|$db_type|$fdate|$fsize|$fname|$f"
        fi
        id=$((id + 1))
    done
}

# ==============================================================================
# Status Report
# ==============================================================================
show_status() {
    local inst_id="${INSTANCE_ID:-database-hub}"
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
    echo -e "${CYAN}${BOLD}                 DATABASE HUB - BACKUP STATUS & INVENTORY               ${NC}"
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
    echo -e "  Instance ID:    ${BOLD}${CYAN}${inst_id}${NC}"
    echo -e "  Env File:       $ENV_FILE"

    echo ""
    echo -e "${BOLD}[Automated Backup Daemon]${NC}"
    get_scheduler_status "$inst_id"

    local schedule_conf="${AUTO_BACKUP_SCHEDULE:-0 2 * * *}"
    parse_schedule "$schedule_conf"
    echo -e "  Config Schedule: $schedule_conf ($SCHEDULE_LABEL)"
    echo -e "  Retention Limit: Keep latest $AUTO_BACKUP_RETENTION backups per database"

    local compressor
    compressor=$(detect_compressor "$BACKUP_COMPRESSION")
    echo -e "  Compressor:     ${GREEN}$compressor (Extreme Compression)${NC}"

    echo ""
    echo -e "${BOLD}[Storage & Backups]${NC}"
    echo -e "  Backup Dir:     $BACKUP_DIR"
    local total_size
    total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "0B")
    echo -e "  Total Storage:  $total_size"
    echo ""

    echo -e "${BOLD}[Available Backup Files]${NC}"
    list_backups "table" ""

    echo ""
    local log_file="$BACKUP_DIR/backup-${inst_id}.log"
    if [ ! -f "$log_file" ] && [ -f "$BACKUP_DIR/backup.log" ]; then
        log_file="$BACKUP_DIR/backup.log"
    fi
    if [ -f "$log_file" ]; then
        echo -e "${BOLD}[Recent Backup Activity for '${inst_id}']${NC}"
        tail -n 10 "$log_file" | sed 's/^/  /'
    fi
    echo -e "${BLUE}========================================================================${NC}"
}

# ==============================================================================
# Main Action Dispatcher
# ==============================================================================
main() {
    local cmd="${ARGS[0]:-status}"
    local sub_arg="${ARGS[1]:-}"

    case "$cmd" in
        run-all)
            log_step "Starting automated backup for active databases [Instance: ${INSTANCE_ID:-database-hub}]..."
            local ts
            ts=$(date "+%Y-%m-%d %H:%M:%S")
            echo "--- Backup Run Started at $ts [Instance: ${INSTANCE_ID:-database-hub}] ---"

            local fail_count=0
            backup_postgres || ((fail_count++))
            backup_mysql || ((fail_count++))
            backup_mongodb || ((fail_count++))
            backup_redis || ((fail_count++))

            prune_backups "$AUTO_BACKUP_RETENTION"
            if [ "$fail_count" -gt 0 ]; then
                log_error "Automated backup run completed with $fail_count failure(s) for [${INSTANCE_ID:-database-hub}]."
                exit 1
            else
                log_success "Automated backup run completed successfully for [${INSTANCE_ID:-database-hub}]."
            fi
            ;;
        run)
            local target="${sub_arg:-all}"
            case "$target" in
                postgres|postgresql) backup_postgres ;;
                mysql)               backup_mysql ;;
                mongodb|mongo)       backup_mongodb ;;
                redis)               backup_redis ;;
                all)
                    backup_postgres || true
                    backup_mysql || true
                    backup_mongodb || true
                    backup_redis || true
                    ;;
                *)
                    log_error "Unknown database target '$target'. Supported: postgres, mysql, mongodb, redis, all"
                    exit 1
                    ;;
            esac
            prune_backups "$AUTO_BACKUP_RETENTION"
            ;;
        prune)
            local ret="${sub_arg:-$AUTO_BACKUP_RETENTION}"
            prune_backups "$ret"
            ;;
        list)
            list_backups "${sub_arg:-table}" "${ARGS[2]:-}"
            ;;
        status)
            show_status
            ;;
        enable)
            local sched="${sub_arg:-${AUTO_BACKUP_SCHEDULE:-daily}}"
            local ret="${ARGS[2]:-${AUTO_BACKUP_RETENTION:-7}}"
            enable_scheduler "$PROJECT_ROOT" "$sched" "$ret" "$ENV_FILE" "${INSTANCE_ID:-database-hub}"
            ;;
        disable)
            disable_scheduler "${INSTANCE_ID:-database-hub}"
            ;;
        *)
            echo "Usage: $0 [--env <path>] {run [db]|run-all|status|list|prune [retention]|enable [schedule] [retention]|disable}"
            exit 1
            ;;
    esac
}

main
