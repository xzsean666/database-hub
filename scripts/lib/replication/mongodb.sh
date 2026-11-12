#!/usr/bin/env bash
# ==============================================================================
# Database Hub - MongoDB Replication Driver (Replica Set rs0)
# Supports: In-place Replica Set Initiation, rs.add() Bootstrap, Status Check
# ==============================================================================

mongodb_make_master() {
    local env_file="$1"
    local master_host="${2:-127.0.0.1}"
    local inst_id="${INSTANCE_ID:-database-hub}"
    local container="${MONGO_CONTAINER_NAME:-${inst_id}-mongodb}"
    local user="${MONGO_INITDB_ROOT_USERNAME:-root}"
    local pass="${MONGO_INITDB_ROOT_PASSWORD:-mongo_root_secure_pass}"
    local port="${MONGO_PORT:-27017}"
    local replset="${MONGO_REPL_SET_NAME:-rs_${inst_id}}"

    log_step "Configuring MongoDB instance [$inst_id] as Replica Set Primary..."

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_error "MongoDB container '$container' is not running."
        return 1
    fi

    # Ensure keyfile exists with proper permissions (user mongodb: 999)
    local keyfile="$PROJECT_ROOT/configs/mongodb/keys/mongo-keyfile"
    if [ ! -f "$keyfile" ]; then
        log_info "Generating cluster shared secret keyfile for MongoDB..."
        mkdir -p "$(dirname "$keyfile")"
        openssl rand -base64 756 > "$keyfile"
        chown 999:999 "$keyfile" 2>/dev/null || true
        chmod 400 "$keyfile"
    else
        chown 999:999 "$keyfile" 2>/dev/null || true
        chmod 400 "$keyfile"
    fi

    # Check if already initiated
    local rs_check
    rs_check=$(docker exec -i "$container" mongosh -u "$user" -p "$pass" --authenticationDatabase admin --quiet --eval "try { rs.status().ok } catch(e) { 0 }" 2>/dev/null || echo "0")

    if [ "$rs_check" = "1" ]; then
        log_info "MongoDB Replica Set '$replset' is already initiated."
    else
        log_info "Initiating MongoDB Replica Set '$replset' on $master_host:$port..."
        docker exec -i "$container" mongosh -u "$user" -p "$pass" --authenticationDatabase admin --quiet --eval "
            rs.initiate({
                _id: '$replset',
                members: [{ _id: 0, host: '$master_host:$port' }]
            });
        " >/dev/null 2>&1 || true
        sleep 3
    fi

    log_success "MongoDB [$inst_id] is active as Replica Set Primary (Set: $replset, Port: $port)."
    return 0
}

mongodb_bootstrap_replica() {
    local master_host="$1"
    local master_port="$2"
    local master_container="$3"
    local master_user="$4"
    local master_pass="$5"
    local slave_host="$6"
    local slave_port="$7"

    log_step "Registering MongoDB replica node ($slave_host:$slave_port) into Primary..."

    local attempts=0
    local max_attempts=15
    while [ "$attempts" -lt "$max_attempts" ]; do
        local res
        res=$(docker exec -i "$master_container" mongosh -u "$master_user" -p "$master_pass" --authenticationDatabase admin --quiet --eval "
            try {
                var status = rs.status();
                var exists = status.members && status.members.some(function(m) { return m.name === '$slave_host:$slave_port'; });
                if (exists) {
                    print('EXISTS');
                } else {
                    var r = rs.add({ host: '$slave_host:$slave_port' });
                    print(r.ok ? 'OK' : 'ERR');
                }
            } catch(e) {
                print('RETRY');
            }
        " 2>/dev/null || echo "RETRY")

        if [[ "$res" == *"OK"* ]] || [[ "$res" == *"EXISTS"* ]]; then
            log_success "MongoDB replica registered. Initial Sync started automatically."
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    log_warn "MongoDB replica node registration may still be pending."
    return 0
}

mongodb_get_lag() {
    local container="$1"
    local user="${2:-root}"
    local pass="${3:-mongo_root_secure_pass}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "STOPPED"
        return
    fi

    local status_json
    status_json=$(docker exec "$container" mongosh -u "$user" -p "$pass" --authenticationDatabase admin --quiet --eval "
        try {
            var s = rs.status();
            var myState = s.myState;
            var stateStr = (myState == 1) ? 'PRIMARY' : (myState == 2) ? 'SECONDARY' : 'OTHER';
            print(stateStr);
        } catch(e) {
            print('STANDALONE');
        }
    " 2>/dev/null || echo "UNKNOWN")

    if [[ "$status_json" == *"SECONDARY"* ]]; then
        echo "REPLICA|SECONDARY (In Sync)"
    elif [[ "$status_json" == *"PRIMARY"* ]]; then
        echo "MASTER|PRIMARY"
    else
        echo "STANDALONE"
    fi
}
