#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Common Utilities & Shared Library
# ==============================================================================

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging Helpers
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_step() {
    echo -e "${CYAN}${BOLD}===> $*${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# ==============================================================================
# SSH Normalization & Execution
# ==============================================================================
setup_ssh_wrapper() {
    local raw_ssh="${1:-}"
    if [ -z "$raw_ssh" ]; then
        NORMALIZED_SSH_ARGS=""
        return
    fi

    # Strip leading "ssh " or "ssh  " with variable spacing
    local cleaned
    cleaned=$(echo "$raw_ssh" | sed -E 's/^[[:space:]]*ssh[[:space:]]+//')

    # Replace leading ~/ with $HOME/
    cleaned="${cleaned//\~\//$HOME/}"

    NORMALIZED_SSH_ARGS="$cleaned"
}

run_remote_cmd() {
    if [ -z "${NORMALIZED_SSH_ARGS:-}" ]; then
        log_error "SSH arguments not initialized."
        return 1
    fi
    # shellcheck disable=SC2086
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $NORMALIZED_SSH_ARGS "$@"
}

get_remote_host() {
    if [ -z "${NORMALIZED_SSH_ARGS:-}" ]; then
        echo "localhost"
        return
    fi

    # Accurately extract remote host token by skipping SSH flag arguments
    local host=""
    local skip=false
    for token in $NORMALIZED_SSH_ARGS; do
        if [ "$skip" = true ]; then
            skip=false
            continue
        fi
        case "$token" in
            -i|-p|-l|-o|-F|-c|-b)
                skip=true
                ;;
            -*)
                ;;
            *)
                host="$token"
                ;;
        esac
    done

    if [ -z "$host" ]; then
        host="localhost"
    fi

    if [[ "$host" == *"@"* ]]; then
        echo "${host#*@}"
    else
        echo "$host"
    fi
}

# ==============================================================================
# Environment Configuration Loader
# ==============================================================================
load_env_file() {
    local env_path="${1:-}"
    local project_root="${2:-$(pwd)}"

    if [ -n "$env_path" ]; then
        if [ ! -f "$env_path" ]; then
            if [ -f "$project_root/$env_path" ]; then
                env_path="$project_root/$env_path"
            else
                log_error "Specified env file not found: $env_path"
                return 1
            fi
        fi
    else
        if [ -f "$project_root/.env" ]; then
            env_path="$project_root/.env"
        elif [ -f "$project_root/.env.example" ]; then
            env_path="$project_root/.env.example"
        else
            log_error "Neither .env nor .env.example found in $project_root"
            return 1
        fi
    fi

    # Convert to absolute path
    local abs_path
    abs_path="$(cd "$(dirname "$env_path")" && pwd)/$(basename "$env_path")"

    # Export variables safely
    set -a
    # shellcheck disable=SC1090
    source "$abs_path"
    set +a

    resolve_database_data_dirs

    export ENV_FILE_LOADED="$abs_path"
    return 0
}

# ==============================================================================
# Database Data Directory Resolver
# Default base directory: /app/database
# Hierarchy: /app/database/<engine>/<container_name>
# If DATA_DIR or <DB>_DATA_DIR is absolute path: respect specified path
# If relative (./...): resolve under /app/database/<engine>/...
# ==============================================================================
_strip_relative_db_prefixes() {
    local sub="$1"
    local db_type="$2"
    sub="${sub#./}"
    local prev=""
    while [ "$sub" != "$prev" ]; do
        prev="$sub"
        if [ "$sub" = "data" ] || [ "$sub" = "$db_type" ]; then
            sub=""
        elif [[ "$sub" == data/* ]]; then
            sub="${sub#data/}"
        elif [[ "$sub" == "$db_type/"* ]]; then
            sub="${sub#"$db_type"/}"
        fi
    done
    sub="${sub%/"$db_type"}"
    echo "${sub%/}"
}

resolve_single_db_dir() {
    local db_type="$1"
    local container_name="$2"
    local specific_dir="${3:-}"
    local global_dir="${4:-}"

    local base_storage="/app/database"
    if [ ! -d "/app/database" ] && [ ! -w "/" ] && [ ! -w "/app" ]; then
        base_storage="${PROJECT_ROOT:-$(pwd)}/data"
    elif [ -d "/app/database" ] && [ ! -w "/app/database" ]; then
        base_storage="${PROJECT_ROOT:-$(pwd)}/data"
    fi

    if [ -n "$specific_dir" ]; then
        specific_dir="${specific_dir%/}"
        if [[ "$specific_dir" =~ ^/ ]]; then
            if [[ "$specific_dir" == *"/$db_type" ]]; then
                echo "${specific_dir}/${container_name}"
            else
                echo "$specific_dir"
            fi
            return 0
        else
            local sub
            sub=$(_strip_relative_db_prefixes "$specific_dir" "$db_type")
            if [ -z "$sub" ]; then
                echo "$base_storage/$db_type/$container_name"
            elif [ "$sub" = "$container_name" ] || [[ "$sub" == *"/$container_name" ]]; then
                echo "$base_storage/$db_type/$sub"
            else
                echo "$base_storage/$db_type/$sub/$container_name"
            fi
            return 0
        fi
    fi

    if [ -n "$global_dir" ]; then
        global_dir="${global_dir%/}"
        if [[ "$global_dir" =~ ^/ ]]; then
            if [[ "$global_dir" == *"/$container_name" ]]; then
                echo "$global_dir"
            elif [[ "$global_dir" == *"/$db_type" ]]; then
                echo "${global_dir}/$container_name"
            else
                echo "${global_dir}/$db_type/$container_name"
            fi
            return 0
        else
            local sub
            sub=$(_strip_relative_db_prefixes "$global_dir" "$db_type")
            if [ -z "$sub" ]; then
                echo "$base_storage/$db_type/$container_name"
            elif [ "$sub" = "$container_name" ] || [[ "$sub" == *"/$container_name" ]]; then
                echo "$base_storage/$db_type/$sub"
            else
                echo "$base_storage/$db_type/$sub/$container_name"
            fi
            return 0
        fi
    fi

    echo "$base_storage/$db_type/$container_name"
}

resolve_database_data_dirs() {
    local inst="${INSTANCE_ID:-database-hub}"

    POSTGRES_CONTAINER_NAME="${POSTGRES_CONTAINER_NAME:-${inst}-postgres}"
    MYSQL_CONTAINER_NAME="${MYSQL_CONTAINER_NAME:-${inst}-mysql}"
    MONGO_CONTAINER_NAME="${MONGO_CONTAINER_NAME:-${inst}-mongodb}"
    REDIS_CONTAINER_NAME="${REDIS_CONTAINER_NAME:-${inst}-redis}"

    POSTGRES_DATA_DIR=$(resolve_single_db_dir "postgres" "$POSTGRES_CONTAINER_NAME" "${POSTGRES_DATA_DIR:-}" "${DATA_DIR:-}")
    MYSQL_DATA_DIR=$(resolve_single_db_dir "mysql" "$MYSQL_CONTAINER_NAME" "${MYSQL_DATA_DIR:-}" "${DATA_DIR:-}")
    MONGO_DATA_DIR=$(resolve_single_db_dir "mongodb" "$MONGO_CONTAINER_NAME" "${MONGO_DATA_DIR:-}" "${DATA_DIR:-}")
    REDIS_DATA_DIR=$(resolve_single_db_dir "redis" "$REDIS_CONTAINER_NAME" "${REDIS_DATA_DIR:-}" "${DATA_DIR:-}")

    export POSTGRES_CONTAINER_NAME MYSQL_CONTAINER_NAME MONGO_CONTAINER_NAME REDIS_CONTAINER_NAME
    export POSTGRES_DATA_DIR MYSQL_DATA_DIR MONGO_DATA_DIR REDIS_DATA_DIR
}

# Normalize comma-separated database selection into canonical names (postgres, mysql, mongodb, redis)
normalize_selected_dbs() {
    local raw_dbs="${1:-all}"
    local seen=" "
    local result=()

    if [ -z "$raw_dbs" ] || [ "$raw_dbs" = "all" ]; then
        printf '%s\n' postgres mysql mongodb redis
        return 0
    fi

    IFS=',' read -ra ADDR <<< "$raw_dbs"
    for db in "${ADDR[@]}"; do
        db=$(echo "$db" | xargs)
        case "$db" in
            postgres|postgresql) db="postgres" ;;
            mysql)               db="mysql" ;;
            mongo|mongodb)       db="mongodb" ;;
            redis)               db="redis" ;;
            all)
                printf '%s\n' postgres mysql mongodb redis
                return 0
                ;;
            *)
                continue
                ;;
        esac
        if [[ "$seen" != *" $db "* ]]; then
            seen="${seen}${db} "
            result+=("$db")
        fi
    done

    if [ ${#result[@]} -gt 0 ]; then
        printf '%s\n' "${result[@]}"
    fi
}

# Create host data directories only for selected databases
ensure_selected_db_data_dirs() {
    local selected_dbs="${1:-all}"
    local db
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        case "$db" in
            postgres) mkdir -p "${POSTGRES_DATA_DIR:-/app/database/postgres/$POSTGRES_CONTAINER_NAME}" 2>/dev/null || true ;;
            mysql)    mkdir -p "${MYSQL_DATA_DIR:-/app/database/mysql/$MYSQL_CONTAINER_NAME}" 2>/dev/null || true ;;
            mongodb)  mkdir -p "${MONGO_DATA_DIR:-/app/database/mongodb/$MONGO_CONTAINER_NAME}" 2>/dev/null || true ;;
            redis)    mkdir -p "${REDIS_DATA_DIR:-/app/database/redis/$REDIS_CONTAINER_NAME}" 2>/dev/null || true ;;
        esac
    done < <(normalize_selected_dbs "$selected_dbs")
}

# Persist resolved *_DATA_DIR for selected databases if missing from env file and ensure host directories exist
persist_selected_db_data_dirs() {
    local env_file="$1"
    local selected_dbs="${2:-all}"
    local db var_name var_val

    while IFS= read -r db; do
        [ -z "$db" ] && continue
        case "$db" in
            postgres) var_name="POSTGRES_DATA_DIR"; var_val="${POSTGRES_DATA_DIR:-}" ;;
            mysql)    var_name="MYSQL_DATA_DIR";    var_val="${MYSQL_DATA_DIR:-}" ;;
            mongodb)  var_name="MONGO_DATA_DIR";    var_val="${MONGO_DATA_DIR:-}" ;;
            redis)    var_name="REDIS_DATA_DIR";    var_val="${REDIS_DATA_DIR:-}" ;;
            *)        continue ;;
        esac
        if [ -n "$var_val" ]; then
            if [ -f "$env_file" ] && ! grep -q "^[[:space:]]*${var_name}=" "$env_file"; then
                echo "${var_name}=${var_val}" >> "$env_file"
            fi
            mkdir -p "$var_val" 2>/dev/null || true
        fi
    done < <(normalize_selected_dbs "$selected_dbs")
}

# ==============================================================================
# Extreme Compression Engine Detection
# Priority: zstd (ultra) -> xz (ultra) -> pigz (fast gzip) -> gzip (standard)
# ==============================================================================
detect_compressor() {
    local preferred="${1:-auto}" # auto, zstd, xz, gzip

    if [ "$preferred" = "zstd" ] || [ "$preferred" = "auto" ]; then
        if command -v zstd >/dev/null 2>&1; then
            # Level 19 with multi-threading gives extreme compression ratio
            echo "zstd -19 -T0 --quiet"
            return 0
        fi
    fi

    if [ "$preferred" = "xz" ] || [ "$preferred" = "auto" ]; then
        if command -v xz >/dev/null 2>&1; then
            # Level 9 with extreme flags and multithreading
            echo "xz -9e -T0 --quiet"
            return 0
        fi
    fi

    if command -v pigz >/dev/null 2>&1; then
        echo "pigz -9"
        return 0
    fi

    echo "gzip -9"
    return 0
}

get_archive_extension() {
    local compressor_cmd="$1"
    case "$compressor_cmd" in
        zstd*) echo "zst" ;;
        xz*)   echo "xz" ;;
        *)     echo "gz" ;;
    esac
}

detect_decompressor() {
    local file="$1"
    case "$file" in
        *.zst)
            if command -v zstd >/dev/null 2>&1; then
                echo "zstd -dc --quiet"
            else
                log_error "zstd is required to decompress $file but is not installed."
                return 1
            fi
            ;;
        *.xz)
            if command -v xz >/dev/null 2>&1; then
                echo "xz -dc --quiet"
            else
                log_error "xz is required to decompress $file but is not installed."
                return 1
            fi
            ;;
        *.gz)
            if command -v pigz >/dev/null 2>&1; then
                echo "pigz -dc"
            else
                echo "gzip -dc"
            fi
            ;;
        *)
            echo "cat"
            ;;
    esac
}

# Human readable bytes
format_bytes() {
    local bytes="$1"
    if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "$bytes"
        return
    fi

    if [ "$bytes" -ge 1073741824 ]; then
        awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b / 1073741824 }'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b / 1048576 }'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN { printf "%.2f KB", b / 1024 }'
    else
        echo "${bytes} B"
    fi
}
