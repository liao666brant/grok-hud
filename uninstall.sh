#!/bin/sh
# Linux uninstaller. Mirrors uninstall.ps1: stops the background monitor,
# removes this plugin's status line configuration, then uninstalls the plugin.
# History, runtime files and backups are preserved.
set -eu

repo_root=$(cd -- "$(dirname -- "$0")" && pwd -P)
if [ -n "${GROK_HOME:-}" ]; then
    grok_home=$GROK_HOME
else
    grok_home=$HOME/.grok
fi
. "$repo_root/scripts/monitor-service.sh"

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    grok_budget_units_owned_by_us || { echo 'The monitor units belong to another application.' >&2; exit 1; }
    grok_budget_stop_monitor_units
    systemctl --user disable "$GROK_BUDGET_MONITOR_SERVICE" "$GROK_BUDGET_MONITOR_TIMER" >/dev/null 2>&1 || true
    unit_dir=$(grok_budget_unit_dir)
    rm -f "$unit_dir/$GROK_BUDGET_MONITOR_SERVICE" "$unit_dir/$GROK_BUDGET_MONITOR_TIMER"
    systemctl --user daemon-reload
fi

config_path="$grok_home/config.toml"
if [ -f "$config_path" ]; then
    tmp="$config_path.grok-budget.tmp"
    rc=0
    awk '
        BEGIN { inblock = 0; seen = 0; removed = 0; blocktext = ""; out = "" }
        {
            if (inblock) {
                if ($0 ~ /^\[/) {
                    inblock = 0
                    if (index(blocktext, "grok-budget") == 0) { out = out blocktext } else { removed = 1 }
                    blocktext = ""
                } else { blocktext = blocktext $0 "\n"; next }
            }
            if (!seen && $0 ~ /^\[ui\.status_line\]/) {
                seen = 1; blocktext = $0 "\n"; inblock = 1; next
            }
            out = out $0 "\n"
        }
        END {
            if (inblock) {
                if (index(blocktext, "grok-budget") == 0) { out = out blocktext } else { removed = 1 }
            }
            printf "%s", out
            exit (removed ? 0 : 2)
        }
    ' "$config_path" > "$tmp" || rc=$?
    if [ "$rc" -eq 0 ]; then
        backup_dir="$grok_home/grok-budget/backups/uninstall-$(date +%Y%m%d-%H%M%S%3N)"
        mkdir -p "$backup_dir"
        cp "$config_path" "$backup_dir/"
        mv "$tmp" "$config_path"
    else
        rm -f "$tmp"
    fi
fi

grok plugin uninstall grok-budget --confirm --keep-data || { echo 'Grok plugin uninstall failed.' >&2; exit 1; }
echo 'Uninstalled. History, runtime files and backups are preserved. Restart Grok to reload its configuration.'