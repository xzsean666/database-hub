#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Deployment Script (Local & Remote)
# Supports: PostgreSQL, MySQL, MongoDB, Redis
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Default values
TARGET="local"           # local or remote
SSH_CMD=""              # Raw SSH command or connection string
ENV_FILE=""             # Path to .env file
SELECTED_DBS="all"      # postgres, mysql, mongodb, redis, all
ACTION="up"             # up, down, restart, status, logs, tune-host
REMOTE_DIR="/opt/database-hub"
TUNE_HOST=false
AUTO_INSTALL_DOCKER=false

# ==============================================================================
# Help Message
# ==============================================================================
show_help() {
    echo -e "${BOLD}Database Hub - Unified Deployment Tool${NC}

Usage:
  ./deploy.sh [OPTIONS]

Options:
  -l, --local                 Deploy on the local machine (default if --ssh is omitted)
  -s, --ssh \"<command>\"       Deploy remotely via SSH command or connection string.
                              Example: -s \"ssh -i ~/ssh/sean -p 22 root@192.168.31.33\"
                              Example: -s \"root@192.168.31.33\"
  -e, --env <path>            Path to .env configuration file (default: ./.env or ./.env.example)
  -d, --db <databases>        Comma-separated list of databases to deploy:
                              postgres, mysql, mongodb, redis, all (default: all)
  -a, --action <action>       Action to perform:
                              up        - Deploy and start services (default)
                              down      - Stop and remove services
                              restart   - Restart services
                              status    - Check running status and health
                              logs      - View container logs
                              tune-host - Apply Linux kernel performance tuning
  -r, --remote-dir <path>     Remote directory on server (default: /opt/database-hub)
      --tune-host             Apply host kernel optimizations (sysctl, THP disable) before deploy
      --install-docker        Automatically install Docker & Compose if missing on remote
  -i, --interactive           Run in interactive prompt mode
  -h, --help                  Show this help message and exit

Examples:
  1. Interactive wizard:
     ./deploy.sh

  2. Local deployment of all databases:
     ./deploy.sh --local --env .env --db all

  3. Remote deployment with SSH key & custom port:
     ./deploy.sh --ssh \"ssh -i ~/ssh/sean -p 22 root@192.168.31.33\" --env .env --db postgres,redis

  4. Remote status check:
     ./deploy.sh --ssh \"ssh -i ~/ssh/sean -p 22 root@192.168.31.33\" --action status"
}

# ==============================================================================
# Parse Arguments
# ==============================================================================
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
                echo -e "${RED}Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
}

# ==============================================================================
# Interactive Mode
# ==============================================================================
run_interactive() {
    echo -e "${CYAN}${BOLD}"
    echo "============================================================"
    echo "          Database Hub - Deployment Setup Wizard            "
    echo "============================================================"
    echo -e "${NC}"

    # 1. Target
    echo -e "${BOLD}Select Deployment Target:${NC}"
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
            echo -e "${RED}SSH connection string cannot be empty for remote deployment.${NC}"
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

    # 3. Database Selection
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

    # 4. Action
    echo ""
    echo -e "${BOLD}Select Action:${NC}"
    echo "  1) up      - Deploy / Update containers"
    echo "  2) down    - Stop containers"
    echo "  3) restart - Restart containers"
    echo "  4) status  - Check health and status"
    echo "  5) logs    - View logs"
    read -rp "Enter choice [1-5] (default: 1): " action_choice
    case "${action_choice:-1}" in
        1) ACTION="up" ;;
        2) ACTION="down" ;;
        3) ACTION="restart" ;;
        4) ACTION="status" ;;
        5) ACTION="logs" ;;
        *) ACTION="up" ;;
    esac

    # 5. Tune Host
    if [ "$ACTION" = "up" ]; then
        echo ""
        read -rp "Apply Linux host performance tuning (sysctl, THP disable)? [y/N]: " tune_choice
        if [[ "$tune_choice" =~ ^[Yy]$ ]]; then
            TUNE_HOST=true
        fi
    fi
}

# ==============================================================================
# Helper: Normalize SSH Command & Execution
# ==============================================================================
setup_ssh_wrapper() {
    # Strip leading "ssh " if present
    local cleaned="${SSH_CMD#ssh }"

    # Replace leading ~ with $HOME for identity files
    cleaned="${cleaned//\~\//$HOME/}"

    NORMALIZED_SSH_ARGS="$cleaned"
}

run_remote_cmd() {
    # shellcheck disable=SC2086
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $NORMALIZED_SSH_ARGS "$@"
}

# Extract remote host IP / hostname from SSH arguments for display
get_remote_host() {
    # Look for user@host or standalone host (last argument in SSH args)
    # shellcheck disable=SC2086
    local last_arg
    last_arg=$(echo "$NORMALIZED_SSH_ARGS" | awk '{print $NF}')
    if [[ "$last_arg" == *"@"* ]]; then
        echo "${last_arg#*@}"
    else
        echo "$last_arg"
    fi
}

# ==============================================================================
# Validate Environment File
# ==============================================================================
validate_env_file() {
    if [ -z "$ENV_FILE" ]; then
        if [ -f "$PROJECT_ROOT/.env" ]; then
            ENV_FILE="$PROJECT_ROOT/.env"
        elif [ -f "$PROJECT_ROOT/.env.example" ]; then
            echo -e "${YELLOW}Notice: .env not found. Automatically copying .env.example -> .env${NC}"
            cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
            ENV_FILE="$PROJECT_ROOT/.env"
        else
            echo -e "${RED}Error: Neither .env nor .env.example found!${NC}"
            exit 1
        fi
    fi

    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Error: Specified env file '$ENV_FILE' does not exist.${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Using environment file: $ENV_FILE${NC}"
}

# ==============================================================================
# Compose Profiles & Flags Builder
# ==============================================================================
build_compose_command() {
    local base_cmd="docker compose --env-file .env"
    
    # Handle profiles
    local profile_flags=""
    if [ "$SELECTED_DBS" = "all" ]; then
        profile_flags="--profile all"
    else
        IFS=',' read -ra ADDR <<< "$SELECTED_DBS"
        for db in "${ADDR[@]}"; do
            db=$(echo "$db" | xargs) # trim whitespace
            case "$db" in
                postgres|postgresql) profile_flags="$profile_flags --profile postgres" ;;
                mysql)               profile_flags="$profile_flags --profile mysql" ;;
                mongo|mongodb)       profile_flags="$profile_flags --profile mongodb" ;;
                redis)               profile_flags="$profile_flags --profile redis" ;;
                all)                 profile_flags="--profile all"; break ;;
                *)
                    echo -e "${YELLOW}Warning: Unknown database '$db', skipping.${NC}"
                    ;;
            esac
        done
    fi

    echo "$base_cmd $profile_flags"
}

# ==============================================================================
# Deployment Display Summary
# ==============================================================================
print_connection_summary() {
    local host="$1"
    
    # Read variables from env file
    local pg_port pg_user pg_pass pg_db
    local my_port my_root_pass my_user my_pass my_db
    local mongo_port mongo_user mongo_pass mongo_db
    local redis_port redis_pass

    pg_port=$(grep -E '^POSTGRES_PORT=' "$ENV_FILE" | cut -d= -f2- || echo "5432")
    pg_user=$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2- || echo "postgres")
    pg_pass=$(grep -E '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || echo "postgres_secure_pass")
    pg_db=$(grep -E '^POSTGRES_DB=' "$ENV_FILE" | cut -d= -f2- || echo "app_db")

    my_port=$(grep -E '^MYSQL_PORT=' "$ENV_FILE" | cut -d= -f2- || echo "3306")
    my_root_pass=$(grep -E '^MYSQL_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || echo "mysql_root_secure_pass")
    my_user=$(grep -E '^MYSQL_USER=' "$ENV_FILE" | cut -d= -f2- || echo "app_user")
    my_pass=$(grep -E '^MYSQL_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || echo "mysql_user_secure_pass")
    my_db=$(grep -E '^MYSQL_DATABASE=' "$ENV_FILE" | cut -d= -f2- || echo "app_db")

    mongo_port=$(grep -E '^MONGO_PORT=' "$ENV_FILE" | cut -d= -f2- || echo "27017")
    mongo_user=$(grep -E '^MONGO_INITDB_ROOT_USERNAME=' "$ENV_FILE" | cut -d= -f2- || echo "root")
    mongo_pass=$(grep -E '^MONGO_INITDB_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || echo "mongo_root_secure_pass")
    mongo_db=$(grep -E '^MONGO_INITDB_DATABASE=' "$ENV_FILE" | cut -d= -f2- || echo "app_db")

    redis_port=$(grep -E '^REDIS_PORT=' "$ENV_FILE" | cut -d= -f2- || echo "6379")
    redis_pass=$(grep -E '^REDIS_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || echo "redis_secure_pass")

    echo ""
    echo -e "${GREEN}${BOLD}========================================================================${NC}"
    echo -e "${GREEN}${BOLD}               DATABASE DEPLOYMENT SUMMARY & ACCESS INFO                ${NC}"
    echo -e "${GREEN}${BOLD}========================================================================${NC}"
    echo -e "Host: ${CYAN}${host}${NC}\n"

    if [[ "$SELECTED_DBS" == *"postgres"* ]] || [ "$SELECTED_DBS" = "all" ]; then
        echo -e "${BOLD}[PostgreSQL 16]${NC}"
        echo -e "  Port:      ${pg_port}"
        echo -e "  Database:  ${pg_db}"
        echo -e "  User:      ${pg_user}"
        echo -e "  Password:  ${pg_pass}"
        echo -e "  URI:       ${CYAN}postgresql://${pg_user}:${pg_pass}@${host}:${pg_port}/${pg_db}${NC}"
        echo -e "  CLI:       psql -h ${host} -p ${pg_port} -U ${pg_user} -d ${pg_db}\n"
    fi

    if [[ "$SELECTED_DBS" == *"mysql"* ]] || [ "$SELECTED_DBS" = "all" ]; then
        echo -e "${BOLD}[MySQL 8.x]${NC}"
        echo -e "  Port:      ${my_port}"
        echo -e "  Database:  ${my_db}"
        echo -e "  User:      ${my_user} (or root)"
        echo -e "  Password:  ${my_pass} (root: ${my_root_pass})"
        echo -e "  CLI:       mysql -h ${host} -P ${my_port} -u ${my_user} -p\n"
    fi

    if [[ "$SELECTED_DBS" == *"mongo"* ]] || [ "$SELECTED_DBS" = "all" ]; then
        echo -e "${BOLD}[MongoDB 7.0]${NC}"
        echo -e "  Port:      ${mongo_port}"
        echo -e "  Database:  ${mongo_db}"
        echo -e "  User:      ${mongo_user}"
        echo -e "  Password:  ${mongo_pass}"
        echo -e "  URI:       ${CYAN}mongodb://${mongo_user}:${mongo_pass}@${host}:${mongo_port}/${mongo_db}?authSource=admin${NC}"
        echo -e "  CLI:       mongosh \"mongodb://${mongo_user}:${mongo_pass}@${host}:${mongo_port}/${mongo_db}?authSource=admin\"\n"
    fi

    if [[ "$SELECTED_DBS" == *"redis"* ]] || [ "$SELECTED_DBS" = "all" ]; then
        echo -e "${BOLD}[Redis 7.2]${NC}"
        echo -e "  Port:      ${redis_port}"
        echo -e "  Password:  ${redis_pass}"
        echo -e "  URI:       ${CYAN}redis://:${redis_pass}@${host}:${redis_port}${NC}"
        echo -e "  CLI:       redis-cli -h ${host} -p ${redis_port} -a ${redis_pass}\n"
    fi
    echo -e "${GREEN}========================================================================${NC}"
}

# ==============================================================================
# Local Execution Routine
# ==============================================================================
deploy_local() {
    echo -e "${BLUE}===> Deploying LOCALLY on current host...${NC}"

    # Verify Docker
    if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
        echo -e "${RED}Error: Docker or Docker Compose is not installed locally.${NC}"
        exit 1
    fi

    # Host Tuning
    if [ "$TUNE_HOST" = true ] || [ "$ACTION" = "tune-host" ]; then
        bash "$PROJECT_ROOT/scripts/tune-host.sh"
        if [ "$ACTION" = "tune-host" ]; then exit 0; fi
    fi

    local compose_base
    compose_base=$(build_compose_command)

    # Ensure .env is linked or copied locally
    if [ "$ENV_FILE" != "$PROJECT_ROOT/.env" ]; then
        cp "$ENV_FILE" "$PROJECT_ROOT/.env"
    fi

    cd "$PROJECT_ROOT"

    case "$ACTION" in
        up)
            echo -e "${BLUE}===> Starting containers ($SELECTED_DBS)...${NC}"
            # shellcheck disable=SC2086
            $compose_base up -d
            echo -e "${GREEN}✓ Containers deployed. Running health verification...${NC}"
            sleep 3
            bash "$PROJECT_ROOT/scripts/healthcheck.sh" "$PROJECT_ROOT/.env"
            print_connection_summary "localhost"
            ;;
        down)
            echo -e "${YELLOW}===> Stopping containers...${NC}"
            # shellcheck disable=SC2086
            $compose_base down
            echo -e "${GREEN}✓ Containers stopped.${NC}"
            ;;
        restart)
            echo -e "${YELLOW}===> Restarting containers...${NC}"
            # shellcheck disable=SC2086
            $compose_base restart
            bash "$PROJECT_ROOT/scripts/healthcheck.sh" "$PROJECT_ROOT/.env"
            ;;
        status)
            bash "$PROJECT_ROOT/scripts/healthcheck.sh" "$PROJECT_ROOT/.env"
            ;;
        logs)
            # shellcheck disable=SC2086
            $compose_base logs -f --tail=100
            ;;
    esac
}

# ==============================================================================
# Remote Execution Routine
# ==============================================================================
deploy_remote() {
    echo -e "${BLUE}===> Deploying REMOTELY via SSH...${NC}"
    setup_ssh_wrapper

    local remote_host
    remote_host=$(get_remote_host)

    # 1. Test SSH Connection
    echo -n "Testing SSH connection to $remote_host... "
    if ! run_remote_cmd "echo SSH_CONNECTED" > /dev/null 2>&1; then
        echo -e "${RED}[FAILED]${NC}"
        echo -e "${RED}Error: Unable to connect via SSH: $SSH_CMD${NC}"
        echo -e "Please check your network, credentials, and identity file permissions."
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC}"

    # 2. Check or install Docker on remote
    echo -n "Checking remote Docker & Docker Compose... "
    if ! run_remote_cmd "command -v docker &>/dev/null && docker compose version &>/dev/null"; then
        echo -e "${YELLOW}[NOT FOUND]${NC}"
        if [ "$AUTO_INSTALL_DOCKER" = true ]; then
            echo -e "${BLUE}Auto-installing Docker & Docker Compose on remote...${NC}"
            cat "$PROJECT_ROOT/scripts/setup-remote-docker.sh" | run_remote_cmd "bash -s"
        else
            read -rp "Docker is not detected on remote. Install Docker automatically? [y/N]: " inst_choice
            if [[ "$inst_choice" =~ ^[Yy]$ ]]; then
                cat "$PROJECT_ROOT/scripts/setup-remote-docker.sh" | run_remote_cmd "bash -s"
            else
                echo -e "${RED}Aborting. Remote system requires Docker and Docker Compose.${NC}"
                exit 1
            fi
        fi
    else
        echo -e "${GREEN}[OK]${NC}"
    fi

    # 3. Remote Host Tuning
    if [ "$TUNE_HOST" = true ] || [ "$ACTION" = "tune-host" ]; then
        echo -e "${BLUE}Applying Linux kernel host optimizations on remote...${NC}"
        cat "$PROJECT_ROOT/scripts/tune-host.sh" | run_remote_cmd "bash -s"
        if [ "$ACTION" = "tune-host" ]; then exit 0; fi
    fi

    # 4. Sync Project Directory to Remote using fast tar stream over SSH
    echo -e "${BLUE}Syncing configuration and files to remote '$REMOTE_DIR'...${NC}"
    tar --exclude='.git' --exclude='data' --exclude='*.log' -czf - -C "$PROJECT_ROOT" . | \
        run_remote_cmd "mkdir -p '$REMOTE_DIR' && tar -xzf - -C '$REMOTE_DIR'"

    # 5. Sync the specified .env file
    echo -e "${BLUE}Deploying environment configuration (.env)...${NC}"
    cat "$ENV_FILE" | run_remote_cmd "cat > '$REMOTE_DIR/.env'"

    local compose_base
    compose_base=$(build_compose_command)

    # 6. Execute Remote Action
    case "$ACTION" in
        up)
            echo -e "${BLUE}===> Deploying containers on remote host ($SELECTED_DBS)...${NC}"
            run_remote_cmd "cd '$REMOTE_DIR' && $compose_base up -d"
            echo -e "${GREEN}✓ Remote deployment initiated. Waiting for healthcheck...${NC}"
            sleep 4
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/healthcheck.sh .env"
            print_connection_summary "$remote_host"
            ;;
        down)
            echo -e "${YELLOW}===> Stopping containers on remote host...${NC}"
            run_remote_cmd "cd '$REMOTE_DIR' && $compose_base down"
            echo -e "${GREEN}✓ Remote containers stopped.${NC}"
            ;;
        restart)
            echo -e "${YELLOW}===> Restarting containers on remote host...${NC}"
            run_remote_cmd "cd '$REMOTE_DIR' && $compose_base restart"
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/healthcheck.sh .env"
            ;;
        status)
            run_remote_cmd "cd '$REMOTE_DIR' && bash scripts/healthcheck.sh .env"
            ;;
        logs)
            run_remote_cmd "cd '$REMOTE_DIR' && $compose_base logs -f --tail=100"
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

    validate_env_file

    if [ "$TARGET" = "remote" ]; then
        deploy_remote
    else
        deploy_local
    fi
}

main "$@"
