#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Universal Restore Engine (Local & Remote SSH)
# Supports PostgreSQL, MySQL, MongoDB, Redis with Extreme Decompression
# Supports multi-database / multi-instance setups via INSTANCE_ID
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared library
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# Default variables
TARGET="local"           # local or remote
SSH_CMD=""              # Raw SSH command or user@host
ENV_FILE=""             # Path to .env file
REMOTE_DIR="/opt/database-hub"
SELECTED_DB=""          # Filter by database type
RESTORE_FILE=""         # Specific file to restore
USE_LATEST=false        # Pick latest backup for database
LIST_ONLY=false         # Only list backups
FORCE_YES=false         # Skip confirmation prompt

show_help() {
    echo -e "${BOLD}Database Hub - Universal Database Restore Tool${NC}

Usage:
  ./restore.sh [OPTIONS]
  bash scripts/restore.sh [OPTIONS]

Options:
  -l, --local                 Restore on local machine (default)
  -s, --ssh \"<command>\"       Restore remotely via SSH command or connection string
                              Example: -s \"ssh -i ~/ssh/key -p 22 root@192.168.31.33\"
                              Example: -s \"root@192.168.31.33\"
  -e, --env <path>            Path to .env configuration file (default: .env or .env.example)
  -r, --remote-dir <path>     Remote database hub directory (default: /opt/database-hub)
  -d, --db <database>         Database type to filter: postgres, mysql, mongodb, redis
  -f, --file <filename>       Specific backup file name or path to restore
      --latest                Automatically restore the latest backup for the specified --db
      --list                  List all available backups on target and exit
  -y, --yes                   Assume Yes to all confirmation prompts (dangerous)
  -i, --interactive           Run in interactive prompt mode
  -h, --help                  Show this help message and exit

Examples:
  1. Interactive restore wizard:
     ./restore.sh

  2. List available remote backups:
     ./restore.sh --ssh \"root@192.168.31.33\" --list

  3. Restore latest PostgreSQL backup remotely using specific .env:
     ./restore.sh --ssh \"root@192.168.31.33\" --env envs/mall.env --db postgres --latest

  4. Restore specific MySQL backup locally:
     ./restore.sh --local --file mysql_mall-db_app_db_20261112_020000.sql.zst"
}

# Parse Command-Line Arguments
parse_args() {
    if [ $# -eq 0 ]; then
        INTERACTIVE_MODE=true
        return
    fi

    INTERACTIVE_MODE=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--local)
                TARGET="local"
                shift
                ;;
            -s|--ssh)
                TARGET="remote"
                SSH_CMD="$2"
                shift 2
                ;;
            -e|--env)
                ENV_FILE="$2"
                shift 2
                ;;
            -r|--remote-dir)
                REMOTE_DIR="$2"
                shift 2
                ;;
            -d|--db)
                SELECTED_DB="$2"
                shift 2
                ;;
            -f|--file)
                RESTORE_FILE="$2"
                shift 2
                ;;
            --latest)
                USE_LATEST=true
                shift
                ;;
            --list)
                LIST_ONLY=true
                shift
                ;;
            -y|--yes)
                FORCE_YES=true
                shift
                ;;
            -i|--interactive)
                INTERACTIVE_MODE=true
                shift
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

run_interactive() {
    echo -e "${CYAN}${BOLD}"
    echo "============================================================"
    echo "            Database Hub - Restore Setup Wizard             "
    echo "============================================================"
    echo -e "${NC}"

    # 1. Target
    echo -e "${BOLD}Select Restore Target:${NC}"
    echo "  1) Local Machine"
    echo "  2) Remote Server (via SSH)"
    read -rp "Enter choice [1-2] (default: 1): " target_choice
    target_choice="${target_choice:-1}"
    if [ "$target_choice" = "2" ]; then
        TARGET="remote"
        echo ""
        echo -e "${BOLD}Enter SSH Connection Command or Destination:${NC}"
        echo "  Examples:"
        echo "    ssh -i ~/ssh/sean -p 22 root@192.168.31.33"
        echo "    root@192.168.31.33"
        read -rp "SSH string: " SSH_CMD
        while [ -z "$SSH_CMD" ]; do
            echo -e "${RED}SSH connection string cannot be empty for remote restore.${NC}"
            read -rp "SSH string: " SSH_CMD
        done
    else
        TARGET="local"
    fi

    # 2. Env File
    echo ""
    echo -e "${BOLD}Path to .env configuration file:${NC}"
    local default_env=".env"
    if [ ! -f "$PROJECT_ROOT/.env" ] && [ -f "$PROJECT_ROOT/.env.example" ]; then
        default_env=".env.example"
    fi
    read -rp "Env file path (default: $default_env): " env_choice
    ENV_FILE="${env_choice:-$default_env}"
}

# Fetch backup file entries from target (Local or Remote)
# Format: ID|INSTANCE|DB|DATE|SIZE|FILENAME|FULLPATH
fetch_backups() {
    local backup_dir
    if [ "$TARGET" = "local" ]; then
        backup_dir="${BACKUP_DIR:-$PROJECT_ROOT/backups}"
        if [ ! -d "$backup_dir" ]; then
            echo ""
            return
        fi

        local id=1
        find "$backup_dir" -maxdepth 1 -type f \( -name "*.zst" -o -name "*.xz" -o -name "*.gz" -o -name "*.sql" -o -name "*.archive" -o -name "*.tar" \) ! -name "*.sha256" | sort -r | while IFS= read -r f; do
            local fname
            fname=$(basename "$f")
            local db_type="unknown"
            case "$fname" in
                postgres_*) db_type="postgres" ;;
                mysql_*)    db_type="mysql" ;;
                mongodb_*)  db_type="mongodb" ;;
                redis_*)    db_type="redis" ;;
            esac

            local extracted_inst="default"
            if [[ "$fname" =~ ^([^_]+)_([^_]+)_ ]]; then
                extracted_inst="${BASH_REMATCH[2]}"
            fi

            local fdate
            fdate=$(date -r "$f" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d'.' -f1 || echo "Unknown")
            local fsize
            fsize=$(du -h "$f" 2>/dev/null | cut -f1 || echo "Unknown")
            echo "$id|$extracted_inst|$db_type|$fdate|$fsize|$fname|$f"
            id=$((id + 1))
        done
    else
        # Remote execution over SSH
        local remote_bdir="$REMOTE_DIR/backups"
        local remote_script='
            bdir="'"$remote_bdir"'"
            if [ ! -d "$bdir" ]; then exit 0; fi
            id=1
            find "$bdir" -maxdepth 1 -type f \( -name "*.zst" -o -name "*.xz" -o -name "*.gz" -o -name "*.sql" -o -name "*.archive" -o -name "*.tar" \) ! -name "*.sha256" | sort -r | while IFS= read -r f; do
                fname=$(basename "$f")
                db="unknown"
                case "$fname" in
                    postgres_*) db="postgres" ;;
                    mysql_*)    db="mysql" ;;
                    mongodb_*)  db="mongodb" ;;
                    redis_*)    db="redis" ;;
                esac
                inst="default"
                if [[ "$fname" =~ ^([^_]+)_([^_]+)_ ]]; then
                    inst="${BASH_REMATCH[2]}"
                fi
                fdate=$(date -r "$f" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d"." -f1 || echo "Unknown")
                fsize=$(du -h "$f" 2>/dev/null | cut -f1 || echo "Unknown")
                echo "$id|$inst|$db|$fdate|$fsize|$fname|$f"
                id=$((id + 1))
            done
        '
        run_remote_cmd "$remote_script" 2>/dev/null || true
    fi
}

# Perform local restore of database
execute_restore_local() {
    local db_type="$1"
    local file_path="$2"
    local fname
    fname=$(basename "$file_path")
    local inst_id="${INSTANCE_ID:-database-hub}"

    log_step "Restoring $db_type [$inst_id] from local file: $fname"

    local decompressor
    decompressor=$(detect_decompressor "$fname")

    case "$db_type" in
        postgres)
            local container="${POSTGRES_CONTAINER_NAME:-${inst_id}-postgres}"
            local user="${POSTGRES_USER:-postgres}"
            local db="${POSTGRES_DB:-app_db}"

            log_info "Streaming decompression ($decompressor) into PostgreSQL container '$container'..."
            if $decompressor "$file_path" | docker exec -i "$container" psql -U "$user" -d "$db" > /dev/null 2>&1; then
                log_success "PostgreSQL ($db) successfully restored!"
            else
                log_warn "Standard psql restore returned non-zero. Retrying against maintenance db 'postgres'..."
                $decompressor "$file_path" | docker exec -i "$container" psql -U "$user" -d postgres
                log_success "PostgreSQL successfully restored!"
            fi
            ;;
        mysql)
            local container="${MYSQL_CONTAINER_NAME:-${inst_id}-mysql}"
            local root_pass="${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}"
            local db="${MYSQL_DATABASE:-app_db}"

            log_info "Streaming decompression ($decompressor) into MySQL container '$container'..."
            $decompressor "$file_path" | docker exec -i "$container" mysql -u root -p"$root_pass"
            log_success "MySQL ($db) successfully restored!"
            ;;
        mongodb)
            local container="${MONGO_CONTAINER_NAME:-${inst_id}-mongodb}"
            local user="${MONGO_INITDB_ROOT_USERNAME:-root}"
            local pass="${MONGO_INITDB_ROOT_PASSWORD:-mongo_root_secure_pass}"
            local db="${MONGO_INITDB_DATABASE:-app_db}"

            log_info "Streaming decompression ($decompressor) into MongoDB container '$container'..."
            $decompressor "$file_path" | docker exec -i "$container" mongorestore \
                --username "$user" \
                --password "$pass" \
                --authenticationDatabase admin \
                --nsInclude="${db}.*" \
                --archive \
                --drop
            log_success "MongoDB ($db) successfully restored!"
            ;;
        redis)
            local container="${REDIS_CONTAINER_NAME:-${inst_id}-redis}"
            local data_dir="${DATA_DIR:-./data}/redis"

            log_info "Stopping Redis container '$container' for consistent snapshot restore..."
            docker stop "$container" >/dev/null

            log_info "Restoring Redis RDB snapshot into $data_dir..."
            mkdir -p "$data_dir"
            $decompressor "$file_path" | tar -xf - -C "$data_dir"

            log_info "Restarting Redis container '$container'..."
            docker start "$container" >/dev/null
            log_success "Redis successfully restored!"
            ;;
        *)
            log_error "Unsupported database type: $db_type"
            return 1
            ;;
    esac
}

# Perform remote restore of database via SSH
execute_restore_remote() {
    local db_type="$1"
    local file_path="$2"
    local fname
    fname=$(basename "$file_path")
    local inst_id="${INSTANCE_ID:-database-hub}"

    local host
    host=$(get_remote_host)
    log_step "Restoring $db_type [$inst_id] remotely on $host from file: $fname"

    local remote_cmd='
        set -euo pipefail
        cd "'"$REMOTE_DIR"'"
        if [ -f .env ]; then
            set -a; source .env; set +a
        fi

        file="'"$file_path"'"
        fname=$(basename "$file")
        inst_id="${INSTANCE_ID:-database-hub}"
        
        # Decompressor detection
        case "$fname" in
            *.zst) DECOMP="zstd -dc --quiet" ;;
            *.xz)  DECOMP="xz -dc --quiet" ;;
            *.gz)  DECOMP="gzip -dc" ;;
            *)     DECOMP="cat" ;;
        esac

        case "'"$db_type"'" in
            postgres)
                container="${POSTGRES_CONTAINER_NAME:-${inst_id}-postgres}"
                user="${POSTGRES_USER:-postgres}"
                db="${POSTGRES_DB:-app_db}"
                echo "[INFO] Streaming decompression into PostgreSQL container '\''$container'\''..."
                if $DECOMP "$file" | docker exec -i "$container" psql -U "$user" -d "$db" > /dev/null 2>&1; then
                    echo "[SUCCESS] PostgreSQL restored successfully."
                else
                    $DECOMP "$file" | docker exec -i "$container" psql -U "$user" -d postgres
                    echo "[SUCCESS] PostgreSQL restored successfully."
                fi
                ;;
            mysql)
                container="${MYSQL_CONTAINER_NAME:-${inst_id}-mysql}"
                root_pass="${MYSQL_ROOT_PASSWORD:-mysql_root_secure_pass}"
                echo "[INFO] Streaming decompression into MySQL container '\''$container'\''..."
                $DECOMP "$file" | docker exec -i "$container" mysql -u root -p"$root_pass"
                echo "[SUCCESS] MySQL restored successfully."
                ;;
            mongodb)
                container="${MONGO_CONTAINER_NAME:-${inst_id}-mongodb}"
                user="${MONGO_INITDB_ROOT_USERNAME:-root}"
                pass="${MONGO_INITDB_ROOT_PASSWORD:-mongo_root_secure_pass}"
                db="${MONGO_INITDB_DATABASE:-app_db}"
                echo "[INFO] Streaming decompression into MongoDB container '\''$container'\''..."
                $DECOMP "$file" | docker exec -i "$container" mongorestore \
                    --username "$user" \
                    --password "$pass" \
                    --authenticationDatabase admin \
                    --nsInclude="${db}.*" \
                    --archive \
                    --drop
                echo "[SUCCESS] MongoDB restored successfully."
                ;;
            redis)
                container="${REDIS_CONTAINER_NAME:-${inst_id}-redis}"
                data_dir="${DATA_DIR:-./data}/redis"
                echo "[INFO] Stopping Redis container '\''$container'\''..."
                docker stop "$container" >/dev/null
                echo "[INFO] Restoring Redis data into $data_dir..."
                mkdir -p "$data_dir"
                $DECOMP "$file" | tar -xf - -C "$data_dir"
                docker start "$container" >/dev/null
                echo "[SUCCESS] Redis restored successfully."
                ;;
        esac
    '

    run_remote_cmd "$remote_cmd"
    log_success "Remote restoration of $db_type completed on $host!"
}

# Main Routine
main() {
    parse_args "$@"

    if [ "${INTERACTIVE_MODE:-false}" = true ]; then
        run_interactive
    fi

    # Environment file setup
    load_env_file "$ENV_FILE" "$PROJECT_ROOT" || true
    local current_inst="${INSTANCE_ID:-database-hub}"

    if [ "$TARGET" = "remote" ]; then
        setup_ssh_wrapper "$SSH_CMD"
        local host
        host=$(get_remote_host)
        log_info "Connecting to remote host: $host"
        if ! run_remote_cmd "echo SSH_CONNECTED" >/dev/null 2>&1; then
            log_error "Unable to connect via SSH to $host using: $SSH_CMD"
            exit 1
        fi
    fi

    # Fetch available backups
    local raw_backups
    raw_backups=$(fetch_backups)

    if [ -z "$raw_backups" ]; then
        log_warn "No backup archives found on target ($TARGET)."
        exit 0
    fi

    # Parse backups into indexed array
    local backup_lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && backup_lines+=("$line")
    done <<< "$raw_backups"

    local total_count=${#backup_lines[@]}

    # Just listing
    if [ "$LIST_ONLY" = true ]; then
        echo -e "\n${BLUE}${BOLD}Available Backups on Target (${TARGET}):${NC}"
        printf "%-4s %-14s %-12s %-20s %-10s %s\n" "ID" "INSTANCE" "DATABASE" "CREATED AT" "SIZE" "FILENAME"
        printf "%-4s %-14s %-12s %-20s %-10s %s\n" "----" "--------------" "------------" "--------------------" "----------" "----------------------------------------"
        for line in "${backup_lines[@]}"; do
            IFS='|' read -r bid binst bdb bdate bsize bname bpath <<< "$line"
            printf "%-4s %-14s %-12s %-20s %-10s %s\n" "$bid" "$binst" "$bdb" "$bdate" "$bsize" "$bname"
        done
        echo ""
        exit 0
    fi

    local target_entry=""

    # 1. Specified by exact file
    if [ -n "$RESTORE_FILE" ]; then
        for line in "${backup_lines[@]}"; do
            IFS='|' read -r bid binst bdb bdate bsize bname bpath <<< "$line"
            if [ "$bname" = "$RESTORE_FILE" ] || [ "$bpath" = "$RESTORE_FILE" ]; then
                target_entry="$line"
                break
            fi
        done
        if [ -z "$target_entry" ]; then
            log_error "Specified backup file '$RESTORE_FILE' not found in backup storage."
            exit 1
        fi
    # 2. Pick latest for specific database
    elif [ "$USE_LATEST" = true ] && [ -n "$SELECTED_DB" ]; then
        for line in "${backup_lines[@]}"; do
            IFS='|' read -r bid binst bdb bdate bsize bname bpath <<< "$line"
            if [ "$bdb" = "$SELECTED_DB" ]; then
                if [ -n "$current_inst" ] && [ "$binst" != "$current_inst" ] && [ "$binst" != "default" ]; then
                    continue
                fi
                target_entry="$line"
                break
            fi
        done
        if [ -z "$target_entry" ]; then
            log_error "No backup found for database '$SELECTED_DB' [Instance: $current_inst]."
            exit 1
        fi
    # 3. Interactive selection
    else
        echo -e "\n${CYAN}${BOLD}Available Database Backups on Target (${TARGET}) [Current Instance: ${current_inst}]:${NC}"
        printf "%-4s %-14s %-12s %-20s %-10s %s\n" "ID" "INSTANCE" "DATABASE" "CREATED AT" "SIZE" "FILENAME"
        printf "%-4s %-14s %-12s %-20s %-10s %s\n" "----" "--------------" "------------" "--------------------" "----------" "----------------------------------------"
        for line in "${backup_lines[@]}"; do
            IFS='|' read -r bid binst bdb bdate bsize bname bpath <<< "$line"
            if [ -n "$SELECTED_DB" ] && [ "$bdb" != "$SELECTED_DB" ]; then
                continue
            fi
            printf "%-4s %-14s %-12s %-20s %-10s %s\n" "$bid" "$binst" "$bdb" "$bdate" "$bsize" "$bname"
        done
        echo ""

        read -rp "Select backup ID to restore [1-$total_count] (or 'q' to quit): " sel_id
        if [ "$sel_id" = "q" ] || [ "$sel_id" = "Q" ] || [ -z "$sel_id" ]; then
            echo "Restore cancelled."
            exit 0
        fi

        for line in "${backup_lines[@]}"; do
            IFS='|' read -r bid binst bdb bdate bsize bname bpath <<< "$line"
            if [ "$bid" = "$sel_id" ]; then
                target_entry="$line"
                break
            fi
        done

        if [ -z "$target_entry" ]; then
            log_error "Invalid selection ID: $sel_id"
            exit 1
        fi
    fi

    IFS='|' read -r t_id t_inst t_db t_date t_size t_name t_path <<< "$target_entry"

    echo ""
    echo -e "${YELLOW}${BOLD}⚠️  CRITICAL RESTORE CONFIRMATION ⚠️${NC}"
    echo -e "You are about to restore the following backup:"
    echo -e "  Instance:  ${CYAN}${t_inst}${NC}"
    echo -e "  Database:  ${CYAN}${t_db}${NC}"
    echo -e "  File:      ${BOLD}${t_name}${NC}"
    echo -e "  Size:      ${t_size}"
    echo -e "  Target:    ${TARGET}"
    echo -e "${RED}This operation will OVERWRITE existing data in the running database container!${NC}"

    if [ "$FORCE_YES" != true ]; then
        read -rp "Are you absolutely sure you want to proceed? [y/N]: " confirm
        if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
            log_warn "Restore aborted by user."
            exit 0
        fi
    fi

    local start_ts
    start_ts=$(date +%s)

    if [ "$TARGET" = "local" ]; then
        execute_restore_local "$t_db" "$t_path"
        echo ""
        log_step "Running health verification..."
        bash "$PROJECT_ROOT/scripts/healthcheck.sh" "$ENV_FILE" || true
    else
        execute_restore_remote "$t_db" "$t_path"
        echo ""
        log_step "Running remote health verification..."
        run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/healthcheck.sh .env" || true
    fi

    local end_ts
    end_ts=$(date +%s)
    local total_duration=$((end_ts - start_ts))

    echo ""
    log_success "🎉 Restore operation for '$t_db' completed successfully in ${total_duration}s!"
}

main "$@"
