#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Cluster Metadata & Topology State Manager
# Scoped per INSTANCE_ID so multiple database stacks coexist without conflict
# ==============================================================================

get_metadata_path() {
    local inst_id="${1:-database-hub}"
    local base_dir="${2:-$PROJECT_ROOT}"
    echo "$base_dir/metadata/${inst_id}.meta.json"
}

save_metadata() {
    local inst_id="$1"
    local json_content="$2"
    local base_dir="${3:-$PROJECT_ROOT}"

    local meta_file
    meta_file=$(get_metadata_path "$inst_id" "$base_dir")
    mkdir -p "$(dirname "$meta_file")"

    echo "$json_content" > "$meta_file"
}

load_metadata() {
    local inst_id="$1"
    local base_dir="${2:-$PROJECT_ROOT}"

    local meta_file
    meta_file=$(get_metadata_path "$inst_id" "$base_dir")

    if [ -f "$meta_file" ]; then
        cat "$meta_file"
        return 0
    fi
    return 1
}

# Fetch metadata from remote server via SSH
fetch_remote_metadata() {
    local raw_ssh="$1"
    local remote_dir="$2"
    local inst_id="$3"

    setup_ssh_wrapper "$raw_ssh"
    local meta_file="$remote_dir/metadata/${inst_id}.meta.json"

    local content
    content=$(run_remote_cmd "[ -f '$meta_file' ] && cat '$meta_file'" || true)

    if [ -n "$content" ]; then
        echo "$content"
        return 0
    fi
    return 1
}

# Extract a field from json string using python3, jq, or grep/sed fallback
read_json_val() {
    local json_str="$1"
    local key="$2"

    if command -v jq >/dev/null 2>&1; then
        echo "$json_str" | jq -r "$key" 2>/dev/null || true
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, json
try:
    d = json.loads('''$json_str''')
    keys = '$key'.replace('//', '').lstrip('.').split('.')
    v = d
    for k in keys:
        if k: v = v.get(k, '')
    print(v if v is not None else '')
except Exception:
    pass
" 2>/dev/null || true
    else
        # Fallback simple grep for flat key
        local clean_key="${key##*.}"
        echo "$json_str" | grep -o "\"$clean_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | cut -d'"' -f4 || true
    fi
}
