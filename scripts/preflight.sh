#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Multi-Instance Pre-Flight Conflict Detector
# Prevents container, Compose project, network, data directory, and port
# collisions across PostgreSQL, MySQL, MongoDB, and Redis deployments.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ENV_FILE="${1:-}"
SELECTED_DBS="${2:-all}"

normalize_path() {
    local p="$1"
    if [ -d "$p" ]; then
        (cd "$p" 2>/dev/null && pwd -P) && return 0
    fi
    if command -v readlink >/dev/null 2>&1; then
        local rp
        rp=$(readlink -m "$p" 2>/dev/null || true)
        if [ -n "$rp" ]; then
            echo "$rp"
            return 0
        fi
    fi
    while [[ "$p" != "/" && "$p" == */ ]]; do
        p="${p%/}"
    done
    echo "$p"
}

# Returns 0 if two host paths are identical or nested inside one another
paths_overlap() {
    local p1 p2
    p1=$(normalize_path "$1")
    p2=$(normalize_path "$2")

    if [ -z "$p1" ] || [ -z "$p2" ]; then
        return 1
    fi
    if [ "$p1" = "$p2" ]; then
        return 0
    fi
    if [[ "$p2" == "$p1/"* ]] || [[ "$p1" == "$p2/"* ]]; then
        return 0
    fi
    return 1
}

normalize_ip() {
    local ip="${1:-}"
    ip="${ip#[}"
    ip="${ip%]}"
    case "$ip" in
        ""|"*"|"0.0.0.0"|"::") echo "*" ;;
        *) echo "$ip" ;;
    esac
}

ips_overlap() {
    local a b
    a=$(normalize_ip "$1")
    b=$(normalize_ip "$2")
    [ "$a" = "*" ] || [ "$b" = "*" ] || [ "$a" = "$b" ]
}

report_conflict() {
    CONFLICTS=$((CONFLICTS + 1))
    log_error "$1"
}

check_network_conflict() {
    local network_name="$1"
    local proj_name="$2"

    if docker network inspect "$network_name" >/dev/null 2>&1; then
        local net_proj
        net_proj=$(docker network inspect --format '{{index .Labels "com.docker.compose.project"}}' "$network_name" 2>/dev/null || true)
        if [ -n "$net_proj" ] && [ "$net_proj" != "$proj_name" ]; then
            report_conflict "Docker network '$network_name' is already owned by Compose project '$net_proj' (current project: '$proj_name'). Set a unique INSTANCE_ID or DOCKER_NETWORK_NAME in your .env."
        fi
    fi
}

check_service_conflicts() {
    local svc="$1"
    local target_ctr="$2"
    local target_data_dir="$3"
    local mount_dest="$4"
    local host_port="$5"
    local var_prefix="$6"
    local proj_name="$7"
    local bind_ip="$8"

    # 0. Managed data directory leaf must match target container name (prevents copy-paste dir reuse)
    local norm_target_dir parent_dir parent_base leaf_dir
    norm_target_dir=$(normalize_path "$target_data_dir")
    parent_dir=$(dirname "$norm_target_dir")
    parent_base=$(basename "$parent_dir")
    leaf_dir=$(basename "$norm_target_dir")
    if [ "$parent_base" = "$svc" ] && [ "$leaf_dir" != "$target_ctr" ]; then
        local managed_prefix=false
        local norm_global=""
        if [ -n "${DATA_DIR:-}" ] && [[ "${DATA_DIR}" = /* ]]; then
            norm_global=$(normalize_path "${DATA_DIR%/}")
        fi
        case "$parent_dir" in
            "/app/database/$svc"|"/var/lib/database-hub/data/$svc"|"${PROJECT_ROOT}/data/$svc")
                managed_prefix=true ;;
        esac
        if [ -n "$norm_global" ] && [ "$parent_dir" = "$norm_global/$svc" ]; then
            managed_prefix=true
        fi
        if [ "$managed_prefix" = true ]; then
            report_conflict "Data directory mismatch for '$svc': ${var_prefix}_DATA_DIR='$target_data_dir' targets leaf '$leaf_dir' instead of container name '$target_ctr'. Use '${var_prefix}_DATA_DIR=\${DATA_DIR}/$svc/\${${var_prefix}_CONTAINER_NAME}' (expected '$parent_dir/$target_ctr')."
        fi
    fi

    # 1. Same Compose project + same service managing a DIFFERENT container name
    local existing_svc_ctr
    while IFS= read -r existing_svc_ctr; do
        [ -z "$existing_svc_ctr" ] && continue
        if [ "$existing_svc_ctr" != "$target_ctr" ]; then
            report_conflict "Compose project '$proj_name' already manages service '$svc' as container '$existing_svc_ctr' (current env wants '$target_ctr'). Deploying would replace '$existing_svc_ctr'. Set a unique INSTANCE_ID and COMPOSE_PROJECT_NAME."
        fi
    done < <(docker ps -a --filter "label=com.docker.compose.project=$proj_name" --filter "label=com.docker.compose.service=$svc" --format '{{.Names}}' 2>/dev/null || true)

    # 2. Target container already exists: verify Compose project & data dir match
    local target_exists=false
    local target_running=false
    if printf '%s\n' "${ALL_CONTAINERS[@]:-}" | grep -qx "$target_ctr"; then
        target_exists=true
        local existing_proj
        existing_proj=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$target_ctr" 2>/dev/null || true)
        if [ -n "$existing_proj" ] && [ "$existing_proj" != "$proj_name" ]; then
            report_conflict "Container name '$target_ctr' already belongs to Compose project '$existing_proj' (current project: '$proj_name'). Set a unique INSTANCE_ID and ${var_prefix}_CONTAINER_NAME."
        fi

        local existing_src
        existing_src=$(docker inspect --format "{{range .Mounts}}{{if and (eq .Type \"bind\") (eq .Destination \"$mount_dest\")}}{{.Source}}{{end}}{{end}}" "$target_ctr" 2>/dev/null || true)
        if [ -n "$existing_src" ]; then
            local norm_existing norm_target
            norm_existing=$(normalize_path "$existing_src")
            norm_target=$(normalize_path "$target_data_dir")
            if [ "$norm_existing" != "$norm_target" ]; then
                report_conflict "Container '$target_ctr' already mounts '$existing_src' at '$mount_dest', whereas this .env specifies '${var_prefix}_DATA_DIR=$target_data_dir'. Refusing to switch data directory on an existing container; use a unique INSTANCE_ID / ${var_prefix}_CONTAINER_NAME or remove the old container first."
            fi
        fi

        local is_running
        is_running=$(docker inspect --format '{{.State.Running}}' "$target_ctr" 2>/dev/null || echo "false")
        if [ "$is_running" = "true" ]; then
            target_running=true
        fi
    fi

    # 3. Cross-container data directory & port collisions
    local other_ctr
    for other_ctr in "${ALL_CONTAINERS[@]:-}"; do
        [ -z "$other_ctr" ] && continue
        [ "$other_ctr" = "$target_ctr" ] && continue

        # 3a. Writable bind mount overlap
        local src
        while IFS= read -r src; do
            [ -z "$src" ] && continue
            if paths_overlap "$target_data_dir" "$src"; then
                report_conflict "Data directory conflict for '$svc': host path '$target_data_dir' (${var_prefix}_DATA_DIR) overlaps with mount '$src' on existing container '$other_ctr'. Set a unique INSTANCE_ID or ${var_prefix}_DATA_DIR."
            fi
        done < <(docker inspect --format '{{range .Mounts}}{{if and (eq .Type "bind") .RW}}{{.Source}}{{"\n"}}{{end}}{{end}}' "$other_ctr" 2>/dev/null || true)

        # 3b. Published port overlap on running containers
        local other_running
        other_running=$(docker inspect --format '{{.State.Running}}' "$other_ctr" 2>/dev/null || echo "false")
        if [ "$other_running" = "true" ]; then
            local binding pub_ip pub_port
            while IFS= read -r binding; do
                [ -z "$binding" ] && continue
                pub_ip="${binding%|*}"
                pub_port="${binding##*|}"
                if [ "$pub_port" = "$host_port" ] && ips_overlap "$bind_ip" "$pub_ip"; then
                    report_conflict "Port conflict for '$svc': ${bind_ip}:${host_port} (${var_prefix}_PORT) is already bound by running container '$other_ctr'. Choose a different ${var_prefix}_PORT."
                fi
            done < <(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostIp}}|{{.HostPort}}{{"\n"}}{{end}}{{end}}' "$other_ctr" 2>/dev/null || true)
        fi
    done

    # 4. Host-level port check if target container is not already running
    if [ "$target_running" = false ] && command -v ss >/dev/null 2>&1; then
        local listen_addr listen_ip
        while IFS= read -r listen_addr; do
            [ -z "$listen_addr" ] && continue
            listen_ip="${listen_addr%:*}"
            if ips_overlap "$bind_ip" "$listen_ip"; then
                report_conflict "Port conflict for '$svc': ${bind_ip}:${host_port} (${var_prefix}_PORT) is already in use on host (listener: $listen_addr). Choose a different ${var_prefix}_PORT."
                break
            fi
        done < <(ss -H -ltn "sport = :$host_port" 2>/dev/null | awk '{print $4}' || true)
    fi
}

main() {
    load_env_file "$ENV_FILE" "$PROJECT_ROOT"

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed on target host."
        exit 1
    fi

    local inst_id="${INSTANCE_ID:-database-hub}"
    local proj_name="${COMPOSE_PROJECT_NAME:-$inst_id}"
    local network_name="${DOCKER_NETWORK_NAME:-${inst_id}-net}"
    local bind_ip="${BIND_IP:-127.0.0.1}"

    CONFLICTS=0
    ALL_CONTAINERS=()
    while IFS= read -r c; do
        [ -n "$c" ] && ALL_CONTAINERS+=("$c")
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)

    check_network_conflict "$network_name" "$proj_name"

    local db
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        case "$db" in
            postgres)
                check_service_conflicts "postgres" "$POSTGRES_CONTAINER_NAME" "$POSTGRES_DATA_DIR" "/var/lib/postgresql/data" "${POSTGRES_PORT:-5432}" "POSTGRES" "$proj_name" "$bind_ip"
                ;;
            mysql)
                check_service_conflicts "mysql" "$MYSQL_CONTAINER_NAME" "$MYSQL_DATA_DIR" "/var/lib/mysql" "${MYSQL_PORT:-3306}" "MYSQL" "$proj_name" "$bind_ip"
                ;;
            mongodb)
                check_service_conflicts "mongodb" "$MONGO_CONTAINER_NAME" "$MONGO_DATA_DIR" "/data/db" "${MONGO_PORT:-27017}" "MONGO" "$proj_name" "$bind_ip"
                ;;
            redis)
                check_service_conflicts "redis" "$REDIS_CONTAINER_NAME" "$REDIS_DATA_DIR" "/data" "${REDIS_PORT:-6379}" "REDIS" "$proj_name" "$bind_ip"
                ;;
        esac
    done < <(normalize_selected_dbs "$SELECTED_DBS")

    if [ "$CONFLICTS" -gt 0 ]; then
        log_error "Pre-flight check failed with $CONFLICTS conflict(s) for instance [$inst_id] ($ENV_FILE_LOADED). Aborting to protect existing databases."
        exit 1
    fi

    log_info "Pre-flight isolation check passed for instance [$inst_id] ($SELECTED_DBS)."
}

main
