#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Unified Management & Deployment CLI (Local & Remote SSH)
# Supports: PostgreSQL, MySQL, MongoDB, Redis
# Features: Modular Deploy, Extreme Auto-Backup, Status Inspection, Universal Restore
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Source shared modules
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/scheduler.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/summary.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/cluster/network.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/cluster/metadata.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/lib/cluster/env-manager.sh"

# Default configuration
TARGET="local"                  # local or remote
SSH_CMD=""                     # Raw SSH command or connection string
ENV_FILE=""                    # Path to .env file
SELECTED_DBS="all"             # postgres, mysql, mongodb, redis, all
ACTION="up"                    # up, down, restart, status, logs, backup, backup-status, restore, tune-host, make-master, deploy-replica, repl-status, scan
REMOTE_DIR="/opt/database-hub"
TUNE_HOST=false
AUTO_INSTALL_DOCKER=false

# Replication configuration
MASTER_ENV=""
MASTER_SSH=""
MAX_RATE="30M"
ROLE=""

# Auto-backup configuration
ENABLE_AUTO_BACKUP=false
AUTO_BACKUP_SCHEDULE="0 2 * * *" # Default: 1 day 1 time (02:00 AM)
AUTO_BACKUP_RETENTION=7          # Max backups retention count

# Restore configuration
RESTORE_FILE=""
USE_LATEST=false
LIST_ONLY=false
FORCE_YES=false

# ==============================================================================
# Help Message
# ==============================================================================
show_help() {
    echo -e "${BOLD}Database Hub - Unified Management & Deployment Tool${NC}

Usage:
  ./dbhub.sh [COMMAND|OPTIONS]

Commands:
  up                          Deploy and start services (default)
  down                        Stop and remove services
  restart                     Restart services
  status                      Check container health & auto-backup status
  logs                        Follow live database logs
  backup                      Trigger immediate database backup
  backup-status               Check auto-backup daemon status, schedule & files
  restore                     Launch universal database restore wizard / tool
  tune-host                   Apply Linux kernel performance tuning
  make-master                 Upgrade database instance to Master
  deploy-replica              Deploy Replica tracking a Master instance
  repl-status                 Check cluster replication status & sync lag
  scan                        Scan all database environments on host

Options:
  -l, --local                    Deploy/manage on the local machine (default if --ssh is omitted)
  -s, --ssh \"<command>\"          Deploy/manage remotely via SSH command or connection string
                                 Example: -s \"ssh -i ~/ssh/key -p 22 root@192.168.31.33\"
                                 Example: -s \"root@192.168.31.33\"
  -e, --env <path>               Path to .env configuration file (default: .env or .env.example)
  -d, --db <databases>           Comma-separated list of databases to deploy / restore:
                                 postgres, mysql, mongodb, redis, all (default: all)
  -a, --action <action>          Action to perform (up, down, restart, status, logs, backup,
                                 backup-status, restore, make-master, deploy-replica, repl-status, scan, tune-host)
  -r, --remote-dir <path>        Remote directory on server (default: /opt/database-hub)
  -f, --file <filename>          Specific backup archive file to restore
      --latest                   Restore the latest backup for specified --db
      --list                     List available backup archives on target and exit
  -y, --yes                      Assume Yes to all confirmation prompts (e.g. restore overwrite)
      --make-master, --upgrade-to-master  Shortcut to upgrade database stack to Master
      --replica, --deploy-replica         Shortcut to deploy database stack as Replica
      --master-ssh \"<cmd>\"       SSH connection command to Master server
      --master-env <path>        Path to Master's .env file
      --max-rate <rate>          Bandwidth limit for initial sync (default: 30M)
      --auto-backup              Enable automated extreme backup daemon
      --backup-schedule <cron>   Backup schedule / frequency:
                                 'daily' (default, 1 day 1 time at 02:00 AM),
                                 '12h' (every 12 hours), '6h' (every 6 hours), or custom cron
      --backup-retention <n>     Max number of backups to retain per database (default: 7)
      --tune-host                Apply host kernel optimizations (sysctl, THP disable) before deploy
      --install-docker           Automatically install Docker & Compose if missing on remote
  -i, --interactive              Run in interactive prompt mode
  -h, --help                     Show this help message and exit

Examples:
  1. Interactive control wizard:
     ./dbhub.sh

  2. Deploy all databases locally with auto-backup enabled:
     ./dbhub.sh --local --auto-backup --backup-schedule daily --backup-retention 7

  3. Remote deployment with SSH key & auto-backup:
     ./dbhub.sh --ssh \"ssh -i ~/ssh/key -p 22 root@192.168.31.33\" --env .env --auto-backup

  4. Inspect backup status remotely:
     ./dbhub.sh backup-status --ssh \"root@192.168.31.33\"

  5. Launch restore tool:
     ./dbhub.sh restore
     ./dbhub.sh restore --list
     ./dbhub.sh restore --ssh \"root@192.168.31.33\" --db postgres --latest"
}

# ==============================================================================
# Parse Command-Line Arguments
# ==============================================================================
parse_args() {
    if [ $# -eq 0 ]; then
        INTERACTIVE_MODE=true
        return
    fi

    INTERACTIVE_MODE=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            up|down|restart|status|logs|backup|backup-status|restore|make-master|deploy-replica|repl-status|scan|tune-host)
                ACTION="$1"
                shift
                ;;
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
            -d|--db)
                SELECTED_DBS="$2"
                shift 2
                ;;
            -a|--action)
                ACTION="$2"
                shift 2
                ;;
            -r|--remote-dir)
                REMOTE_DIR="$2"
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
            --make-master|--upgrade-to-master)
                ACTION="make-master"
                shift
                ;;
            --replica|--deploy-replica)
                ACTION="deploy-replica"
                ROLE="replica"
                shift
                ;;
            --scan)
                ACTION="scan"
                shift
                ;;
            --repl-status)
                ACTION="repl-status"
                shift
                ;;
            --master-ssh)
                MASTER_SSH="$2"
                shift 2
                ;;
            --master-env)
                MASTER_ENV="$2"
                shift 2
                ;;
            --max-rate)
                MAX_RATE="$2"
                shift 2
                ;;
            --auto-backup)
                ENABLE_AUTO_BACKUP=true
                shift
                ;;
            --backup-schedule)
                ENABLE_AUTO_BACKUP=true
                AUTO_BACKUP_SCHEDULE="$2"
                shift 2
                ;;
            --backup-retention)
                AUTO_BACKUP_RETENTION="$2"
                shift 2
                ;;
            --tune-host)
                TUNE_HOST=true
                shift
                ;;
            --install-docker)
                AUTO_INSTALL_DOCKER=true
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

# ==============================================================================
# Interactive Setup Wizard
# ==============================================================================
run_interactive() {
    echo -e "${CYAN}${BOLD}"
    echo "============================================================"
    echo "       Database Hub - Unified Control & Deployment CLI      "
    echo "============================================================"
    echo -e "${NC}"

    # 1. Target
    echo -e "${BOLD}Select Target Machine:${NC}"
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
            echo -e "${RED}SSH connection string cannot be empty for remote operation.${NC}"
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

    # 3. Action Selection
    echo ""
    echo -e "${BOLD}Select Action:${NC}"
    echo "  1) up            - Deploy / Update database containers"
    echo "  2) status        - Check container health & status"
    echo "  3) backup        - Trigger immediate database backup"
    echo "  4) backup-status - Check auto-backup daemon, schedule & files"
    echo "  5) restore       - Restore database from backup"
    echo "  6) logs          - View container logs"
    echo "  7) restart       - Restart containers"
    echo "  8) down          - Stop and remove containers"
    echo "  9) tune-host     - Apply Linux host kernel tuning"
    echo " 10) make-master   - Upgrade database instance to Master"
    echo " 11) deploy-replica- Deploy new Replica from Master environment"
    echo " 12) repl-status   - Check replication sync lag & cluster health"
    echo " 13) scan          - Scan all database environments on host"
    read -rp "Enter choice [1-13] (default: 1): " action_choice
    case "${action_choice:-1}" in
        1) ACTION="up" ;;
        2) ACTION="status" ;;
        3) ACTION="backup" ;;
        4) ACTION="backup-status" ;;
        5) ACTION="restore" ;;
        6) ACTION="logs" ;;
        7) ACTION="restart" ;;
        8) ACTION="down" ;;
        9) ACTION="tune-host" ;;
        10) ACTION="make-master" ;;
        11) ACTION="deploy-replica" ;;
        12) ACTION="repl-status" ;;
        13) ACTION="scan" ;;
        *) ACTION="up" ;;
    esac

    # If action is deploy-replica, interactively guide Master discovery
    if [ "$ACTION" = "deploy-replica" ]; then
        echo ""
        echo -e "${BOLD}Deploy Replica Configuration Wizard:${NC}"
        read -rp "Enter Master SSH connection string (leave blank if Master is local): " master_ssh_input
        MASTER_SSH="$master_ssh_input"

        echo -e "\n${CYAN}Scanning available database environments on Master...${NC}"
        local master_envs=()
        if [ -n "$MASTER_SSH" ]; then
            while IFS= read -r line; do
                if [ -n "$line" ]; then master_envs+=("$line"); fi
            done < <(scan_remote_env_files "$MASTER_SSH" "$REMOTE_DIR")
        else
            while IFS= read -r line; do
                if [ -n "$line" ]; then master_envs+=("$line"); fi
            done < <(scan_env_files "$PROJECT_ROOT")
        fi

        if [ ${#master_envs[@]} -gt 0 ]; then
            echo -e "${BOLD}Select Master Environment to replicate:${NC}"
            local idx=1
            for e in "${master_envs[@]}"; do
                IFS='|' read -r ep ei er ed <<< "$e"
                echo "  $idx) $ep (Instance: $ei, DBs: $ed)"
                ((idx++))
            done
            read -rp "Enter choice [1-${#master_envs[@]}] (default: 1): " env_pick
            env_pick="${env_pick:-1}"
            local selected_line="${master_envs[$((env_pick-1))]}"
            IFS='|' read -r MASTER_ENV m_inst_id _ _ <<< "$selected_line"
            log_info "Selected Master env: $MASTER_ENV [Instance: $m_inst_id]"
        else
            read -rp "Enter path to Master .env file (default: .env): " master_env_input
            MASTER_ENV="${master_env_input:-.env}"
        fi

        echo ""
        echo -e "${BOLD}Select Databases to Replicate:${NC}"
        echo "  1) All databases"
        echo "  2) PostgreSQL only"
        echo "  3) MySQL only"
        echo "  4) MongoDB only"
        echo "  5) Redis only"
        read -rp "Enter choice [1-5] (default: 1): " repl_db_choice
        case "${repl_db_choice:-1}" in
            1) SELECTED_DBS="all" ;;
            2) SELECTED_DBS="postgres" ;;
            3) SELECTED_DBS="mysql" ;;
            4) SELECTED_DBS="mongodb" ;;
            5) SELECTED_DBS="redis" ;;
            *) SELECTED_DBS="all" ;;
        esac

        read -rp "Initial full sync bandwidth limit [default: 30M]: " rate_choice
        MAX_RATE="${rate_choice:-30M}"

        # Automatically generate replica env file if needed
        local is_same="false"
        if [ -z "$SSH_CMD" ] && [ -z "$MASTER_SSH" ]; then
            is_same="true"
        elif [ "$SSH_CMD" = "$MASTER_SSH" ]; then
            is_same="true"
        fi

        local derived_env="envs/${m_inst_id:-dbhub}-replica.env"
        log_info "Deriving replica configuration into: $derived_env"
        local master_local_file="$PROJECT_ROOT/$MASTER_ENV"
        if [ ! -f "$master_local_file" ] && [ -f "$MASTER_ENV" ]; then
            master_local_file="$MASTER_ENV"
        fi

        # If master is remote, download master env to temp
        if [ -n "$MASTER_SSH" ] && [ ! -f "$master_local_file" ]; then
            setup_ssh_wrapper "$MASTER_SSH"
            master_local_file="/tmp/master_${m_inst_id:-dbhub}.env"
            run_remote_cmd "cat '$REMOTE_DIR/$MASTER_ENV'" > "$master_local_file"
        fi

        local m_host="127.0.0.1"
        if [ -n "$MASTER_SSH" ]; then
            m_host=$(get_remote_host)
        fi

        derive_replica_env "$master_local_file" "$PROJECT_ROOT/$derived_env" "$m_host" "$is_same" 10 "$MAX_RATE"
        ENV_FILE="$derived_env"
        log_success "Generated replica configuration: $ENV_FILE"
    fi

    # If action is up (Deploy), ask about databases and auto-backup
    if [ "$ACTION" = "up" ]; then
        echo ""
        echo -e "${BOLD}Select Databases to Deploy:${NC}"
        echo "  1) All (PostgreSQL, MySQL, MongoDB, Redis)"
        echo "  2) PostgreSQL only"
        echo "  3) MySQL only"
        echo "  4) MongoDB only"
        echo "  5) Redis only"
        echo "  6) Custom combination (e.g. postgres,redis)"
        read -rp "Enter choice [1-6] (default: 1): " db_choice
        case "${db_choice:-1}" in
            1) SELECTED_DBS="all" ;;
            2) SELECTED_DBS="postgres" ;;
            3) SELECTED_DBS="mysql" ;;
            4) SELECTED_DBS="mongodb" ;;
            5) SELECTED_DBS="redis" ;;
            6)
                read -rp "Enter database names separated by commas (postgres,mysql,mongodb,redis): " custom_dbs
                SELECTED_DBS="$custom_dbs"
                ;;
            *) SELECTED_DBS="all" ;;
        esac

        # Auto-backup configuration prompt
        echo ""
        echo -e "${BOLD}Automated Extreme Backup:${NC}"
        read -rp "Enable automated extreme backup daemon? [Y/n]: " auto_bk_choice
        auto_bk_choice="${auto_bk_choice:-y}"
        if [[ "$auto_bk_choice" =~ ^[Yy]$ ]]; then
            ENABLE_AUTO_BACKUP=true
            echo -e "Select Backup Frequency:"
            echo "  1) Once a day (Daily at 02:00 AM - Recommended)"
            echo "  2) Twice a day (Every 12 hours)"
            echo "  3) Every 6 hours"
            echo "  4) Custom cron expression (e.g. 0 3 * * *)"
            read -rp "Enter frequency choice [1-4] (default: 1): " freq_choice
            case "${freq_choice:-1}" in
                1) AUTO_BACKUP_SCHEDULE="0 2 * * *" ;;
                2) AUTO_BACKUP_SCHEDULE="0 */12 * * *" ;;
                3) AUTO_BACKUP_SCHEDULE="0 */6 * * *" ;;
                4)
                    read -rp "Enter cron expression (m h dom mon dow): " custom_cron
                    AUTO_BACKUP_SCHEDULE="${custom_cron:-0 2 * * *}"
                    ;;
                *) AUTO_BACKUP_SCHEDULE="0 2 * * *" ;;
            esac

            read -rp "Maximum number of backups to keep per database [default: 7]: " ret_input
            AUTO_BACKUP_RETENTION="${ret_input:-7}"
        else
            ENABLE_AUTO_BACKUP=false
        fi

        # Tune host prompt
        echo ""
        read -rp "Apply Linux host performance tuning (sysctl, THP disable)? [y/N]: " tune_choice
        if [[ "$tune_choice" =~ ^[Yy]$ ]]; then
            TUNE_HOST=true
        fi
    fi
}

# ==============================================================================
# Compose Command Builder
# ==============================================================================
build_compose_command() {
    local env_path="${1:-.env}"
    local proj_name="${COMPOSE_PROJECT_NAME:-${INSTANCE_ID:-database-hub}}"
    local base_cmd="docker compose -p $proj_name --env-file $env_path"
    local profile_flags=""

    if [ "$SELECTED_DBS" = "all" ]; then
        profile_flags="--profile all"
    else
        IFS=',' read -ra ADDR <<< "$SELECTED_DBS"
        for db in "${ADDR[@]}"; do
            db=$(echo "$db" | xargs)
            case "$db" in
                postgres|postgresql) profile_flags="$profile_flags --profile postgres" ;;
                mysql)               profile_flags="$profile_flags --profile mysql" ;;
                mongo|mongodb)       profile_flags="$profile_flags --profile mongodb" ;;
                redis)               profile_flags="$profile_flags --profile redis" ;;
                all)                 profile_flags="--profile all"; break ;;
                *)
                    log_warn "Unknown database '$db', skipping profile."
                    ;;
            esac
        done
    fi

    echo "$base_cmd $profile_flags"
}

# ==============================================================================
# Local Execution Routine
# ==============================================================================
ensure_mongodb_keyfile() {
    local keyfile="$PROJECT_ROOT/configs/mongodb/keys/mongo-keyfile"
    if [ ! -f "$keyfile" ]; then
        mkdir -p "$(dirname "$keyfile")"
        if command -v openssl >/dev/null 2>&1; then
            openssl rand -base64 756 > "$keyfile"
        else
            head -c 512 /dev/urandom | base64 > "$keyfile"
        fi
        chown 999:999 "$keyfile" 2>/dev/null || true
        chmod 400 "$keyfile" 2>/dev/null || true
    fi
}

execute_local() {
    log_step "Executing '$ACTION' locally on current host [Instance: ${INSTANCE_ID:-database-hub}]..."

    # Verify Docker installation
    if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
        log_error "Docker or Docker Compose is not installed locally."
        exit 1
    fi

    # Host Tuning
    if [ "$TUNE_HOST" = true ] || [ "$ACTION" = "tune-host" ]; then
        bash "$PROJECT_ROOT/scripts/tune-host.sh"
        if [ "$ACTION" = "tune-host" ]; then exit 0; fi
    fi

    ensure_mongodb_keyfile

    # Ensure database host directories exist
    mkdir -p "${POSTGRES_DATA_DIR:-/app/database/postgres/$POSTGRES_CONTAINER_NAME}" \
             "${MYSQL_DATA_DIR:-/app/database/mysql/$MYSQL_CONTAINER_NAME}" \
             "${MONGO_DATA_DIR:-/app/database/mongodb/$MONGO_CONTAINER_NAME}" \
             "${REDIS_DATA_DIR:-/app/database/redis/$REDIS_CONTAINER_NAME}" 2>/dev/null || true

    local compose_base
    compose_base=$(build_compose_command "$ENV_FILE")

    cd "$PROJECT_ROOT"

    case "$ACTION" in
        up)
            log_step "Starting containers ($SELECTED_DBS) for instance [${INSTANCE_ID:-database-hub}]..."
            # shellcheck disable=SC2086
            $compose_base up -d
            log_success "Containers deployed. Running health verification..."
            sleep 3
            bash "$PROJECT_ROOT/scripts/healthcheck.sh" "$ENV_FILE"
            print_connection_summary "localhost" "$ENV_FILE" "$SELECTED_DBS"

            # Auto-backup configuration
            if [ "$ENABLE_AUTO_BACKUP" = true ]; then
                log_step "Configuring and starting automated backup daemon for [${INSTANCE_ID:-database-hub}]..."
                bash "$PROJECT_ROOT/scripts/backup.sh" --env "$ENV_FILE" enable "$AUTO_BACKUP_SCHEDULE" "$AUTO_BACKUP_RETENTION"
                echo ""
                bash "$PROJECT_ROOT/scripts/backup.sh" --env "$ENV_FILE" status
            fi
            ;;
        down)
            log_warn "Stopping containers for [${INSTANCE_ID:-database-hub}]..."
            # shellcheck disable=SC2086
            $compose_base down
            log_success "Containers stopped."
            ;;
        restart)
            log_step "Restarting containers for [${INSTANCE_ID:-database-hub}]..."
            # shellcheck disable=SC2086
            $compose_base restart
            bash "$PROJECT_ROOT/scripts/healthcheck.sh" "$ENV_FILE"
            ;;
        status)
            bash "$PROJECT_ROOT/scripts/healthcheck.sh" "$ENV_FILE"
            echo ""
            bash "$PROJECT_ROOT/scripts/backup.sh" --env "$ENV_FILE" status
            ;;
        logs)
            # shellcheck disable=SC2086
            $compose_base logs -f --tail=100
            ;;
        backup)
            log_step "Triggering manual backup for instance [${INSTANCE_ID:-database-hub}]..."
            bash "$PROJECT_ROOT/scripts/backup.sh" --env "$ENV_FILE" run-all
            ;;
        backup-status)
            bash "$PROJECT_ROOT/scripts/backup.sh" --env "$ENV_FILE" status
            ;;
        restore)
            local restore_cmd=("$PROJECT_ROOT/scripts/restore.sh" --local)
            if [ -n "$ENV_FILE" ]; then restore_cmd+=(--env "$ENV_FILE"); fi
            if [ -n "$SELECTED_DBS" ] && [ "$SELECTED_DBS" != "all" ]; then restore_cmd+=(--db "$SELECTED_DBS"); fi
            if [ -n "$RESTORE_FILE" ]; then restore_cmd+=(--file "$RESTORE_FILE"); fi
            if [ "$USE_LATEST" = true ]; then restore_cmd+=(--latest); fi
            if [ "$LIST_ONLY" = true ]; then restore_cmd+=(--list); fi
            if [ "$FORCE_YES" = true ]; then restore_cmd+=(--yes); fi
            if [ "${INTERACTIVE_MODE:-false}" = true ]; then restore_cmd+=(--interactive); fi
            bash "${restore_cmd[@]}"
            ;;
        make-master)
            log_step "Upgrading instance [${INSTANCE_ID:-database-hub}] to Master..."
            bash "$PROJECT_ROOT/scripts/replication.sh" make-master --env "$ENV_FILE" --db "$SELECTED_DBS"
            ;;
        deploy-replica)
            log_step "Deploying replica for [${INSTANCE_ID:-database-hub}]..."
            bash "$PROJECT_ROOT/scripts/replication.sh" deploy-replica --env "$ENV_FILE" --master-env "${MASTER_ENV:-}" --master-ssh "${MASTER_SSH:-}" --db "$SELECTED_DBS" --max-rate "$MAX_RATE"
            ;;
        repl-status)
            bash "$PROJECT_ROOT/scripts/replication.sh" status --env "$ENV_FILE"
            ;;
        scan)
            bash "$PROJECT_ROOT/scripts/replication.sh" scan
            ;;
        *)
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac
}

# ==============================================================================
# Remote Execution Routine
# ==============================================================================
execute_remote() {
    setup_ssh_wrapper "$SSH_CMD"
    local remote_host
    remote_host=$(get_remote_host)

    log_step "Executing '$ACTION' remotely on $remote_host via SSH..."

    # 1. Test SSH Connection
    echo -n "Testing SSH connection to $remote_host... "
    if ! run_remote_cmd "echo SSH_CONNECTED" > /dev/null 2>&1; then
        echo -e "${RED}[FAILED]${NC}"
        log_error "Unable to connect via SSH: $SSH_CMD"
        echo -e "Please check your network, credentials, and identity file permissions."
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC}"

    # Fast remote actions that can execute immediately without re-sync
    if [ "$ACTION" = "backup-status" ]; then
        run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/backup.sh --env '${ENV_FILE:-.env}' status"
        return
    elif [ "$ACTION" = "backup" ]; then
        run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/backup.sh --env '${ENV_FILE:-.env}' run-all"
        return
    elif [ "$ACTION" = "restore" ]; then
        local restore_cmd=("$PROJECT_ROOT/scripts/restore.sh" --ssh "$SSH_CMD")
        if [ -n "$ENV_FILE" ]; then restore_cmd+=(--env "$ENV_FILE"); fi
        if [ -n "$REMOTE_DIR" ]; then restore_cmd+=(--remote-dir "$REMOTE_DIR"); fi
        if [ -n "$SELECTED_DBS" ] && [ "$SELECTED_DBS" != "all" ]; then restore_cmd+=(--db "$SELECTED_DBS"); fi
        if [ -n "$RESTORE_FILE" ]; then restore_cmd+=(--file "$RESTORE_FILE"); fi
        if [ "$USE_LATEST" = true ]; then restore_cmd+=(--latest); fi
        if [ "$LIST_ONLY" = true ]; then restore_cmd+=(--list); fi
        if [ "$FORCE_YES" = true ]; then restore_cmd+=(--yes); fi
        if [ "${INTERACTIVE_MODE:-false}" = true ]; then restore_cmd+=(--interactive); fi
        bash "${restore_cmd[@]}"
        return
    elif [ "$ACTION" = "repl-status" ]; then
        run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/replication.sh status --env '${ENV_FILE:-.env}'"
        return
    elif [ "$ACTION" = "scan" ]; then
        run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/replication.sh scan"
        return
    fi

    # 2. Check or install Docker on remote
    echo -n "Checking remote Docker & Docker Compose... "
    if ! run_remote_cmd "command -v docker &>/dev/null && docker compose version &>/dev/null"; then
        echo -e "${YELLOW}[NOT FOUND]${NC}"
        if [ "$AUTO_INSTALL_DOCKER" = true ]; then
            log_info "Auto-installing Docker & Docker Compose on remote..."
            cat "$PROJECT_ROOT/scripts/setup-remote-docker.sh" | run_remote_cmd "bash -s"
        else
            read -rp "Docker is not detected on remote. Install Docker automatically? [y/N]: " inst_choice
            if [[ "$inst_choice" =~ ^[Yy]$ ]]; then
                cat "$PROJECT_ROOT/scripts/setup-remote-docker.sh" | run_remote_cmd "bash -s"
            else
                log_error "Aborting. Remote system requires Docker and Docker Compose."
                exit 1
            fi
        fi
    else
        echo -e "${GREEN}[OK]${NC}"
    fi

    # 3. Remote Host Tuning
    if [ "$TUNE_HOST" = true ] || [ "$ACTION" = "tune-host" ]; then
        log_info "Applying Linux kernel host optimizations on remote..."
        cat "$PROJECT_ROOT/scripts/tune-host.sh" | run_remote_cmd "bash -s"
        if [ "$ACTION" = "tune-host" ]; then exit 0; fi
    fi

    # 4. Sync Project Directory to Remote using fast tar stream over SSH
    log_info "Syncing configuration and files to remote '$REMOTE_DIR'..."
    tar --exclude='.git' --exclude='data' --exclude='*.log' --exclude='backups' -czf - -C "$PROJECT_ROOT" . | \
        run_remote_cmd "mkdir -p '$REMOTE_DIR' && tar -xzf - -C '$REMOTE_DIR'"

    # 5. Sync the specified .env file safely to its relative path
    local remote_env_rel="${ENV_FILE:-.env}"
    if [[ "$remote_env_rel" = /* ]]; then
        remote_env_rel="${remote_env_rel#$PROJECT_ROOT/}"
    fi
    remote_env_rel="${remote_env_rel#./}"

    log_info "Deploying environment configuration ($remote_env_rel)..."
    run_remote_cmd "mkdir -p '$REMOTE_DIR/$(dirname "$remote_env_rel")'"
    cat "$ENV_FILE" | run_remote_cmd "cat > '$REMOTE_DIR/$remote_env_rel'"

    # Ensure resolved host database directories exist and env has explicit data paths
    run_remote_cmd "
        grep -q '^[[:space:]]*POSTGRES_DATA_DIR=' '$REMOTE_DIR/$remote_env_rel' || echo 'POSTGRES_DATA_DIR=$POSTGRES_DATA_DIR' >> '$REMOTE_DIR/$remote_env_rel';
        grep -q '^[[:space:]]*MYSQL_DATA_DIR=' '$REMOTE_DIR/$remote_env_rel' || echo 'MYSQL_DATA_DIR=$MYSQL_DATA_DIR' >> '$REMOTE_DIR/$remote_env_rel';
        grep -q '^[[:space:]]*MONGO_DATA_DIR=' '$REMOTE_DIR/$remote_env_rel' || echo 'MONGO_DATA_DIR=$MONGO_DATA_DIR' >> '$REMOTE_DIR/$remote_env_rel';
        grep -q '^[[:space:]]*REDIS_DATA_DIR=' '$REMOTE_DIR/$remote_env_rel' || echo 'REDIS_DATA_DIR=$REDIS_DATA_DIR' >> '$REMOTE_DIR/$remote_env_rel';
        mkdir -p '$POSTGRES_DATA_DIR' '$MYSQL_DATA_DIR' '$MONGO_DATA_DIR' '$REDIS_DATA_DIR' 2>/dev/null || true
    "

    local compose_base
    compose_base=$(build_compose_command "$remote_env_rel")

    # 6. Execute Remote Action
    case "$ACTION" in
        up)
            log_step "Deploying containers on remote host ($SELECTED_DBS) [Instance: ${INSTANCE_ID:-database-hub}]..."
            run_remote_cmd "cd '$REMOTE_DIR' && $compose_base up -d"
            log_success "Remote deployment initiated. Waiting for healthcheck..."
            sleep 4
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/healthcheck.sh '$remote_env_rel'"
            print_connection_summary "$remote_host" "$ENV_FILE" "$SELECTED_DBS"

            if [ "$ENABLE_AUTO_BACKUP" = true ]; then
                log_step "Configuring and starting automated backup daemon on remote..."
                run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/backup.sh --env '$remote_env_rel' enable '$AUTO_BACKUP_SCHEDULE' '$AUTO_BACKUP_RETENTION'"
                echo ""
                run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/backup.sh --env '$remote_env_rel' status"
            fi
            ;;
        make-master)
            log_step "Upgrading instance to Master on remote host..."
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/replication.sh make-master --env '$remote_env_rel' --db '$SELECTED_DBS'"
            ;;
        deploy-replica)
            log_step "Deploying replica on remote host..."
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/replication.sh deploy-replica --env '$remote_env_rel' --master-env '${MASTER_ENV:-}' --master-ssh '${MASTER_SSH:-}' --db '$SELECTED_DBS' --max-rate '$MAX_RATE'"
            ;;
        down)
            log_warn "Stopping containers on remote host..."
            run_remote_cmd "cd '$REMOTE_DIR' && $compose_base down"
            log_success "Remote containers stopped."
            ;;
        restart)
            log_step "Restarting containers on remote host..."
            run_remote_cmd "cd '$REMOTE_DIR' && $compose_base restart"
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/healthcheck.sh '$remote_env_rel'"
            ;;
        status)
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/healthcheck.sh '$remote_env_rel'"
            echo ""
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/backup.sh --env '$remote_env_rel' status"
            ;;
        logs)
            run_remote_cmd "cd '$REMOTE_DIR' && $compose_base logs -f --tail=100"
            ;;
        *)
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac
}

# ==============================================================================
# Main Entrypoint
# ==============================================================================
main() {
    parse_args "$@"

    if [ "${INTERACTIVE_MODE:-false}" = true ]; then
        run_interactive
    fi

    # Auto-derive replica environment if target env file doesn't exist yet but master env is provided
    if [ "$ACTION" = "deploy-replica" ] && [ -n "$MASTER_ENV" ] && [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; then
        log_info "Replica env '$ENV_FILE' does not exist. Deriving from Master env '$MASTER_ENV'..."
        local is_same="true"
        if [ "$TARGET" = "remote" ] || [ -n "$MASTER_SSH" ]; then is_same="false"; fi
        local m_host="${MASTER_HOST:-}"
        if [ -z "$m_host" ]; then
            m_host=$(detect_primary_ip)
        fi
        derive_replica_env "$MASTER_ENV" "$ENV_FILE" "$m_host" "$is_same" 10 "$MAX_RATE"
    fi

    load_env_file "$ENV_FILE" "$PROJECT_ROOT" || true
    ENV_FILE="${ENV_FILE_LOADED:-$ENV_FILE}"

    if [ "$TARGET" = "remote" ]; then
        execute_remote
    else
        execute_local
    fi
}

main "$@"
