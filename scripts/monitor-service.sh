# Shared by the Linux installer and unit-definition / recovery tests. POSIX sh.
# Mirrors the Windows Task Scheduler semantics of scripts/monitor-task.ps1:
# one native monitor, started at login, re-pulled every minute when stopped,
# never duplicated while running.

GROK_HUD_MONITOR_SERVICE='grok-hud-monitor.service'
GROK_HUD_MONITOR_TIMER='grok-hud-monitor.timer'
GROK_HUD_MONITOR_DESCRIPTION='Grok HUD account quota monitor (managed by grok-hud installer)'
GROK_HUD_TIMER_DESCRIPTION='Grok HUD monitor watchdog (managed by grok-hud installer)'
GROK_HUD_LEGACY_MONITOR_SERVICE='grok-budget-monitor.service'
GROK_HUD_LEGACY_MONITOR_TIMER='grok-budget-monitor.timer'
GROK_HUD_LEGACY_MONITOR_DESCRIPTION='Grok Budget account quota monitor (managed by grok-budget installer)'
GROK_HUD_LEGACY_TIMER_DESCRIPTION='Grok Budget monitor watchdog (managed by grok-budget installer)'

grok_hud_unit_dir() {
    printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Reject characters systemd's ExecStart double quoting cannot carry safely.
grok_hud_check_unit_args() {
    case "$1" in *'"'*) return 1 ;; esac
    case "$2" in *'"'*) return 1 ;; esac
    return 0
}

grok_hud_monitor_service_text() {
    # $1 = runtime monitor executable, $2 = grok home
    grok_hud_check_unit_args "$1" "$2" || return 1
    cat <<EOF
[Unit]
Description=$GROK_HUD_MONITOR_DESCRIPTION

[Service]
Type=simple
ExecStart="$1" --grok-home "$2"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOF
}

grok_hud_monitor_timer_text() {
    cat <<EOF
[Unit]
Description=$GROK_HUD_TIMER_DESCRIPTION

[Timer]
OnCalendar=minutely
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

# Refuse to touch unit files whose Description names another application.
grok_hud_units_owned_by_us() {
    unit_dir=$(grok_hud_unit_dir)
    for unit in "$GROK_HUD_MONITOR_SERVICE" "$GROK_HUD_MONITOR_TIMER"; do
        path="$unit_dir/$unit"
        [ -f "$path" ] || continue
        case "$unit" in
            *.timer) expected=$GROK_HUD_TIMER_DESCRIPTION ;;
            *) expected=$GROK_HUD_MONITOR_DESCRIPTION ;;
        esac
        desc=$(sed -n 's/^Description=//p' "$path" | head -n 1)
        if [ "$desc" != "$expected" ]; then
            echo "Unit $unit belongs to another application." >&2
            return 1
        fi
    done
    return 0
}

grok_hud_legacy_units_owned_by_us() {
    unit_dir=$(grok_hud_unit_dir)
    for unit in "$GROK_HUD_LEGACY_MONITOR_SERVICE" "$GROK_HUD_LEGACY_MONITOR_TIMER"; do
        path="$unit_dir/$unit"
        [ -f "$path" ] || continue
        case "$unit" in
            *.timer) expected=$GROK_HUD_LEGACY_TIMER_DESCRIPTION ;;
            *) expected=$GROK_HUD_LEGACY_MONITOR_DESCRIPTION ;;
        esac
        desc=$(sed -n 's/^Description=//p' "$path" | head -n 1)
        if [ "$desc" != "$expected" ]; then
            echo "Legacy unit $unit belongs to another application." >&2
            return 1
        fi
    done
    return 0
}

# Stop the timer first so its next fire cannot race the update or uninstall.
grok_hud_stop_monitor_units() {
    systemctl --user stop "$GROK_HUD_MONITOR_TIMER" >/dev/null 2>&1 || true
    systemctl --user stop "$GROK_HUD_MONITOR_SERVICE" >/dev/null 2>&1 || true
}

# Stop and disable the pre-rename units but keep their files so a failed
# upgrade can restore them.
grok_hud_disable_legacy_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl --user show-environment >/dev/null 2>&1 || return 0
    grok_hud_legacy_units_owned_by_us || return 1
    systemctl --user stop "$GROK_HUD_LEGACY_MONITOR_TIMER" >/dev/null 2>&1 || true
    systemctl --user stop "$GROK_HUD_LEGACY_MONITOR_SERVICE" >/dev/null 2>&1 || true
    systemctl --user disable "$GROK_HUD_LEGACY_MONITOR_TIMER" "$GROK_HUD_LEGACY_MONITOR_SERVICE" >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
}

grok_hud_enable_legacy_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl --user show-environment >/dev/null 2>&1 || return 0
    grok_hud_legacy_units_owned_by_us || return 1
    unit_dir=$(grok_hud_unit_dir)
    for unit in "$GROK_HUD_LEGACY_MONITOR_SERVICE" "$GROK_HUD_LEGACY_MONITOR_TIMER"; do
        [ -f "$unit_dir/$unit" ] || return 1
    done
    systemctl --user enable "$GROK_HUD_LEGACY_MONITOR_TIMER" "$GROK_HUD_LEGACY_MONITOR_SERVICE" || return 1
    systemctl --user start "$GROK_HUD_LEGACY_MONITOR_TIMER" "$GROK_HUD_LEGACY_MONITOR_SERVICE" || return 1
}

# Remove units from the pre-rename grok-budget installation after verifying
# their ownership, so an upgrade leaves exactly one monitor behind.
grok_hud_remove_legacy_units() {
    grok_hud_disable_legacy_units || return 1
    unit_dir=$(grok_hud_unit_dir)
    rm -f "$unit_dir/$GROK_HUD_LEGACY_MONITOR_SERVICE" "$unit_dir/$GROK_HUD_LEGACY_MONITOR_TIMER"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
}

grok_hud_wait_monitor_inactive() {
    timeout=${1:-15}
    end=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$end" ]; do
        state=$(systemctl --user is-active "$GROK_HUD_MONITOR_SERVICE" 2>/dev/null || true)
        [ "$state" = "active" ] || return 0
        sleep 1
    done
    echo 'Previous quota monitor did not stop.' >&2
    return 1
}

# Catch immediate startup failures instead of accepting a transient active state.
grok_hud_wait_monitor_active() {
    timeout=${1:-15}
    end=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$end" ]; do
        state=$(systemctl --user is-active "$GROK_HUD_MONITOR_SERVICE" 2>/dev/null || true)
        if [ "$state" = "active" ]; then
            sleep 1
            state=$(systemctl --user is-active "$GROK_HUD_MONITOR_SERVICE" 2>/dev/null || true)
            [ "$state" = "active" ] && return 0
        fi
        sleep 1
    done
    echo 'Quota monitor did not stay running. Backups have been preserved.' >&2
    return 1
}
