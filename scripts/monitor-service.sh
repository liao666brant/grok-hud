# Shared by the Linux installer and unit-definition / recovery tests. POSIX sh.
# Mirrors the Windows Task Scheduler semantics of scripts/monitor-task.ps1:
# one native monitor, started at login, re-pulled every minute when stopped,
# never duplicated while running.

GROK_BUDGET_MONITOR_SERVICE='grok-budget-monitor.service'
GROK_BUDGET_MONITOR_TIMER='grok-budget-monitor.timer'
GROK_BUDGET_MONITOR_DESCRIPTION='Grok Budget account quota monitor (managed by grok-budget installer)'
GROK_BUDGET_TIMER_DESCRIPTION='Grok Budget monitor watchdog (managed by grok-budget installer)'

grok_budget_unit_dir() {
    printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Reject characters systemd's ExecStart double quoting cannot carry safely.
grok_budget_check_unit_args() {
    case "$1" in *'"'*) return 1 ;; esac
    case "$2" in *'"'*) return 1 ;; esac
    return 0
}

grok_budget_monitor_service_text() {
    # $1 = runtime monitor executable, $2 = grok home
    grok_budget_check_unit_args "$1" "$2" || return 1
    cat <<EOF
[Unit]
Description=$GROK_BUDGET_MONITOR_DESCRIPTION

[Service]
Type=simple
ExecStart="$1" --grok-home "$2"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOF
}

grok_budget_monitor_timer_text() {
    cat <<EOF
[Unit]
Description=$GROK_BUDGET_TIMER_DESCRIPTION

[Timer]
OnCalendar=minutely
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

# Refuse to touch unit files whose Description names another application.
grok_budget_units_owned_by_us() {
    unit_dir=$(grok_budget_unit_dir)
    for unit in "$GROK_BUDGET_MONITOR_SERVICE" "$GROK_BUDGET_MONITOR_TIMER"; do
        path="$unit_dir/$unit"
        [ -f "$path" ] || continue
        case "$unit" in
            *.timer) expected=$GROK_BUDGET_TIMER_DESCRIPTION ;;
            *) expected=$GROK_BUDGET_MONITOR_DESCRIPTION ;;
        esac
        desc=$(sed -n 's/^Description=//p' "$path" | head -n 1)
        if [ "$desc" != "$expected" ]; then
            echo "Unit $unit belongs to another application." >&2
            return 1
        fi
    done
    return 0
}

# Stop the timer first so its next fire cannot race the update or uninstall.
grok_budget_stop_monitor_units() {
    systemctl --user stop "$GROK_BUDGET_MONITOR_TIMER" >/dev/null 2>&1 || true
    systemctl --user stop "$GROK_BUDGET_MONITOR_SERVICE" >/dev/null 2>&1 || true
}

grok_budget_wait_monitor_inactive() {
    timeout=${1:-15}
    end=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$end" ]; do
        state=$(systemctl --user is-active "$GROK_BUDGET_MONITOR_SERVICE" 2>/dev/null || true)
        [ "$state" = "active" ] || return 0
        sleep 1
    done
    echo 'Previous quota monitor did not stop.' >&2
    return 1
}

# Catch immediate startup failures instead of accepting a transient active state.
grok_budget_wait_monitor_active() {
    timeout=${1:-15}
    end=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$end" ]; do
        state=$(systemctl --user is-active "$GROK_BUDGET_MONITOR_SERVICE" 2>/dev/null || true)
        if [ "$state" = "active" ]; then
            sleep 1
            state=$(systemctl --user is-active "$GROK_BUDGET_MONITOR_SERVICE" 2>/dev/null || true)
            [ "$state" = "active" ] && return 0
        fi
        sleep 1
    done
    echo 'Quota monitor did not stay running. Backups have been preserved.' >&2
    return 1
}