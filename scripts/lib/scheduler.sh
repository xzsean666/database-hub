#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Auto-Backup Scheduler & Daemon Management
# Supports Systemd Timers (preferred) and Cron (fallback)
# Isolated per INSTANCE_ID so multiple database stacks coexist without conflicts
# ==============================================================================

# Convert user frequency/cron input into Systemd OnCalendar & Cron format
parse_schedule() {
    local input="${1:-daily}"
    local calendar="*-*-* 02:00:00"
    local cron_expr="0 2 * * *"
    local label="Daily at 02:00 AM"

    case "$input" in
        daily|"1d"|"1day"|"1_day"|"24h"|"0 2 * * *")
            calendar="*-*-* 02:00:00"
            cron_expr="0 2 * * *"
            label="Daily at 02:00 AM"
            ;;
        "12h"|"twice_daily"|"0 */12 * * *")
            calendar="*-*-* 00,12:00:00"
            cron_expr="0 */12 * * *"
            label="Every 12 Hours (00:00 & 12:00)"
            ;;
        "6h"|"0 */6 * * *")
            calendar="*-*-* 00,06,12,18:00:00"
            cron_expr="0 */6 * * *"
            label="Every 6 Hours"
            ;;
        "hourly"|"1h"|"0 * * * *")
            calendar="*-*-* *:00:00"
            cron_expr="0 * * * *"
            label="Every Hour"
            ;;
        *)
            # Check if input has 5 cron fields
            local field_count
            field_count=$(echo "$input" | awk '{print NF}')
            if [ "$field_count" -eq 5 ]; then
                cron_expr="$input"
                local m h d mon dow
                read -r m h d mon dow <<< "$input"
                if [ "$d" = "*" ] && [ "$mon" = "*" ] && [ "$dow" = "*" ]; then
                    calendar="*-*-* $(printf "%02d" "$h"):$(printf "%02d" "$m"):00"
                else
                    calendar="" # Rely on cron if complex
                fi
                label="Custom schedule ($cron_expr)"
            else
                calendar="*-*-* 02:00:00"
                cron_expr="0 2 * * *"
                label="Daily at 02:00 AM"
            fi
            ;;
    esac

    SCHEDULE_CALENDAR="$calendar"
    SCHEDULE_CRON="$cron_expr"
    SCHEDULE_LABEL="$label"
}

is_systemd_available() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        return 0
    fi
    return 1
}

# Enable and start Auto-Backup for specific instance
enable_scheduler() {
    local project_dir="$1"
    local raw_schedule="${2:-daily}"
    local retention="${3:-7}"
    local env_path="${4:-$project_dir/.env}"
    local inst_id="${5:-${INSTANCE_ID:-database-hub}}"

    parse_schedule "$raw_schedule"

    local service_name="dbhub-backup-${inst_id}"
    local systemd_service_file="/etc/systemd/system/${service_name}.service"
    local systemd_timer_file="/etc/systemd/system/${service_name}.timer"
    local cron_d_file="/etc/cron.d/${service_name}"

    local backup_script="$project_dir/scripts/backup.sh"
    local log_file="$project_dir/backups/backup-${inst_id}.log"

    mkdir -p "$project_dir/backups"

    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo "[ERROR] Root or sudo access is required to install auto-backup daemon." >&2
            return 1
        fi
    fi

    # Try Systemd Timer first if available and OnCalendar is non-empty
    if is_systemd_available && [ -n "$SCHEDULE_CALENDAR" ]; then
        echo -e "\033[0;34m[INFO]\033[0m Installing Systemd timer for automated backups [Instance: ${inst_id}]..."

        # 1. Create Systemd Service
        $SUDO tee "$systemd_service_file" > /dev/null << EOF
[Unit]
Description=Database Hub Automated Extreme Backup Service (${inst_id})
After=docker.service network.target
Wants=docker.service

[Service]
Type=oneshot
WorkingDirectory="$project_dir"
Environment=AUTO_BACKUP_RETENTION=$retention
Environment=INSTANCE_ID=$inst_id
Environment=ENV_FILE=$env_path
ExecStart=/usr/bin/env bash "$backup_script" run-all --env "$env_path"
StandardOutput=append:$log_file
StandardError=append:$log_file

[Install]
WantedBy=multi-user.target
EOF

        # 2. Create Systemd Timer
        $SUDO tee "$systemd_timer_file" > /dev/null << EOF
[Unit]
Description=Database Hub Automated Backup Timer [${inst_id}] ($SCHEDULE_LABEL)
After=docker.service

[Timer]
OnCalendar=$SCHEDULE_CALENDAR
Persistent=true

[Install]
WantedBy=timers.target
EOF

        $SUDO systemctl daemon-reload
        $SUDO systemctl enable --now "${service_name}.timer" > /dev/null 2>&1

        if [ -f "$cron_d_file" ]; then
            $SUDO rm -f "$cron_d_file"
        fi

        echo -e "\033[0;32m[SUCCESS]\033[0m Systemd auto-backup timer enabled for '${inst_id}'! ($SCHEDULE_LABEL)"
        return 0
    fi

    # Fallback: Linux Cron
    echo -e "\033[0;34m[INFO]\033[0m Installing Cron job for automated backups [Instance: ${inst_id}]..."
    if [ -d "/etc/cron.d" ]; then
        $SUDO tee "$cron_d_file" > /dev/null << EOF
# Database Hub Automated Backup Job for ${inst_id}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
AUTO_BACKUP_RETENTION=$retention
INSTANCE_ID=$inst_id
$SCHEDULE_CRON root cd "$project_dir" && bash "$backup_script" run-all --env "$env_path" >> "$log_file" 2>&1
EOF
        $SUDO chmod 644 "$cron_d_file"
        echo -e "\033[0;32m[SUCCESS]\033[0m Cron auto-backup scheduled in $cron_d_file! ($SCHEDULE_LABEL)"
        return 0
    else
        local marker="DATABASE_HUB_BACKUP_${inst_id}"
        local cron_line="$SCHEDULE_CRON cd \"$project_dir\" && AUTO_BACKUP_RETENTION=$retention INSTANCE_ID=$inst_id bash \"$backup_script\" run-all --env \"$env_path\" >> \"$log_file\" 2>&1 # $marker"
        (crontab -l 2>/dev/null | grep -v "$marker" || true; echo "$cron_line") | crontab -
        echo -e "\033[0;32m[SUCCESS]\033[0m Crontab auto-backup scheduled for '${inst_id}'! ($SCHEDULE_LABEL)"
        return 0
    fi
}

# Disable and stop Auto-Backup for specific instance
disable_scheduler() {
    local inst_id="${1:-${INSTANCE_ID:-database-hub}}"
    local service_name="dbhub-backup-${inst_id}"
    local systemd_service_file="/etc/systemd/system/${service_name}.service"
    local systemd_timer_file="/etc/systemd/system/${service_name}.timer"
    local cron_d_file="/etc/cron.d/${service_name}"
    local marker="DATABASE_HUB_BACKUP_${inst_id}"

    local SUDO=""
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    fi

    local disabled=false

    if is_systemd_available && [ -f "$systemd_timer_file" ]; then
        $SUDO systemctl disable --now "${service_name}.timer" > /dev/null 2>&1 || true
        $SUDO rm -f "$systemd_timer_file" "$systemd_service_file"
        $SUDO systemctl daemon-reload > /dev/null 2>&1 || true
        disabled=true
    fi

    if [ -f "$cron_d_file" ]; then
        $SUDO rm -f "$cron_d_file"
        disabled=true
    fi

    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q "$marker"; then
            crontab -l 2>/dev/null | grep -v "$marker" | crontab -
            disabled=true
        fi
    fi

    if [ "$disabled" = true ]; then
        echo -e "\033[0;32m[SUCCESS]\033[0m Auto-backup scheduler for '${inst_id}' has been disabled."
    else
        echo -e "\033[1;33m[WARN]\033[0m No active auto-backup scheduler found for '${inst_id}'."
    fi
}

# Query scheduler status for specific instance
get_scheduler_status() {
    local inst_id="${1:-${INSTANCE_ID:-database-hub}}"
    local service_name="dbhub-backup-${inst_id}"
    local systemd_timer_file="/etc/systemd/system/${service_name}.timer"
    local cron_d_file="/etc/cron.d/${service_name}"
    local marker="DATABASE_HUB_BACKUP_${inst_id}"

    local active=false
    local mode="None"
    local next_run="N/A"
    local last_run="N/A"

    if is_systemd_available && [ -f "$systemd_timer_file" ]; then
        if systemctl is-active --quiet "${service_name}.timer" 2>/dev/null; then
            active=true
            mode="Systemd Timer (${service_name}.timer)"
            next_run=$(systemctl list-timers "${service_name}.timer" --no-legend 2>/dev/null | awk '{print $1, $2, $3}' || echo "Pending")
            last_run=$(systemctl list-timers "${service_name}.timer" --no-legend 2>/dev/null | awk '{print $5, $6, $7}' || echo "N/A")
        fi
    fi

    if [ "$active" = false ]; then
        if [ -f "$cron_d_file" ]; then
            active=true
            mode="System Cron ($cron_d_file)"
        elif command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "$marker"; then
            active=true
            mode="User Crontab ($marker)"
        fi
    fi

    if [ "$active" = true ]; then
        echo -e "  Status:        \033[0;32m● ACTIVE\033[0m"
        echo -e "  Engine:        $mode"
        if [[ "$mode" == *"Systemd Timer"* ]]; then
            echo -e "  Next Trigger:  $next_run"
            echo -e "  Last Trigger:  $last_run"
        fi
    else
        echo -e "  Status:        \033[1;33m○ INACTIVE\033[0m (Auto-backup not enabled for '${inst_id}')"
    fi
}
