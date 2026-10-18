#!/bin/sh
# Linux installer. Registers the plugin, wires the status line, and installs
# systemd user units for the background monitor. Mirrors install.ps1.
set -eu

usage() {
    echo 'Usage: ./install.sh [--build]' >&2
    exit 1
}

build=0
for arg in "$@"; do
    case "$arg" in
        --build) build=1 ;;
        *) usage ;;
    esac
done

repo_root=$(cd -- "$(dirname -- "$0")" && pwd -P)
plugin_source="$repo_root/grok-budget"
binary="$plugin_source/grok-budget.exe"
monitor_binary="$plugin_source/grok-budget-monitor.exe"

if [ -n "${GROK_HOME:-}" ]; then
    grok_home=$GROK_HOME
else
    grok_home=$HOME/.grok
fi
grok_home_input=$grok_home
if ! grok_home=$(cd -- "$grok_home" && pwd -P); then
    echo "Grok home does not exist: $grok_home_input" >&2
    exit 1
fi
case "$grok_home" in
    *'"'*) echo 'Grok home cannot contain a double quote.' >&2; exit 1 ;;
esac

command -v jq >/dev/null 2>&1 || { echo 'jq is required but not on PATH.' >&2; exit 1; }
command -v grok >/dev/null 2>&1 || { echo 'grok CLI not found on PATH.' >&2; exit 1; }
. "$repo_root/scripts/monitor-service.sh"

# Build when requested, or when the packaged binaries are missing or lost
# their executable bit (a git checkout without the mode records it nowhere).
if [ "$build" -eq 1 ] || [ ! -x "$binary" ] || [ ! -x "$monitor_binary" ]; then
    (cd "$repo_root" && cargo build --release --locked)
    cp "$repo_root/target/release/grok-budget" "$binary"
    cp "$repo_root/target/release/grok-budget-monitor" "$monitor_binary"
fi
chmod +x "$binary" "$monitor_binary"

grok plugin validate "$plugin_source" || { echo 'Plugin validation failed.' >&2; exit 1; }

plugin_list=$(grok plugin list --json)
plugin_field() {
    printf '%s' "$plugin_list" | jq -r "[.[]? | select(.name? == \"grok-budget\")][0].$1 // \"\""
}
existing_source=$(plugin_field 'source')
existing_path=$(plugin_field 'path')

expected_version=$(jq -r '.version' "$plugin_source/plugin.json")
binary_version=$("$binary" --version)
[ "$binary_version" = "grok-budget $expected_version" ] || { echo 'Manifest and executable versions differ.' >&2; exit 1; }

if [ -n "$existing_source" ] && [ -d "$existing_source" ]; then
    old_source=$(cd -- "$existing_source" && pwd -P)
    if [ "$old_source" != "$plugin_source" ]; then
        echo "Existing plugin comes from another directory: $old_source" >&2
        exit 1
    fi
fi

grok_budget_units_owned_by_us || exit 1
systemd_ok=0
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemd_ok=1
fi

# Back up BEFORE Grok mutates the installation or the plugin registry.
stamp=$(date +%Y%m%d-%H%M%S%3N)
backup="$grok_home/grok-budget/backups/$stamp"
mkdir -p "$backup"
config_path="$grok_home/config.toml"
launcher="$grok_home/grok-budget/statusline.sh"
for file in "$config_path" "$launcher" "$grok_home/installed-plugins/registry.json"; do
    if [ -f "$file" ]; then cp "$file" "$backup/"; fi
done
if [ -n "$existing_path" ] && [ -d "$existing_path" ]; then
    cp -R "$existing_path" "$backup/previous-plugin"
fi
if [ "$systemd_ok" -eq 1 ]; then
    unit_dir=$(grok_budget_unit_dir)
    for unit in "$GROK_BUDGET_MONITOR_SERVICE" "$GROK_BUDGET_MONITOR_TIMER"; do
        if [ -f "$unit_dir/$unit" ]; then cp "$unit_dir/$unit" "$backup/$unit"; fi
    done
fi

if [ -n "$existing_source" ]; then
    grok plugin update grok-budget
    plugin_list=$(grok plugin list --json)
    registered_version=$(plugin_field 'version')
    registered_source=$(plugin_field 'source')
    if [ "$registered_version" != "$expected_version" ] || [ "$registered_source" != "$plugin_source" ]; then
        # Local update is a no-op in Grok 1.0.41. Re-register via the official CLI.
        # Keep already-open status lines usable while the copied plugin is replaced.
        rollback_exe="$backup/previous-plugin/grok-budget.exe"
        if [ -f "$rollback_exe" ]; then
            printf '#!/bin/sh\nexec "%s" --statusline\n' "$rollback_exe" > "$launcher"
            chmod 0755 "$launcher"
        fi
        grok plugin uninstall grok-budget --confirm --keep-data
        grok plugin install "$plugin_source" --trust
    fi
else
    grok plugin install "$plugin_source" --trust
fi
grok plugin enable grok-budget

plugin_list=$(grok plugin list --json)
registered_version=$(plugin_field 'version')
installed_path=$(plugin_field 'path')
[ -n "$installed_path" ] || { echo 'Plugin registration validation failed.' >&2; exit 1; }
[ "$registered_version" = "$expected_version" ] || { echo 'Plugin registration/version validation failed.' >&2; exit 1; }

publish_file() {
    src=$1
    dst=$2
    mkdir -p "$(dirname -- "$dst")"
    attempt=0
    while [ "$attempt" -lt 40 ]; do
        cp "$src" "$dst" 2>/dev/null && return 0
        attempt=$((attempt + 1))
        sleep 0.25
    done
    echo "Cannot publish $dst" >&2
    return 1
}

# Grok's local-plugin update can leave a copied installation stale: publish explicitly.
installed_abs=$(cd -- "$installed_path" && pwd -P)
if [ "$installed_abs" != "$plugin_source" ]; then
    for relative in grok-budget.exe grok-budget-monitor.exe plugin.json hooks/hooks.json commands/budget.md report.html; do
        publish_file "$plugin_source/$relative" "$installed_abs/$relative"
    done
    chmod +x "$installed_abs/grok-budget.exe" "$installed_abs/grok-budget-monitor.exe"
fi
"$installed_abs/grok-budget.exe" --version >/dev/null || { echo 'Installed Rust binary failed validation.' >&2; exit 1; }

# A versioned independent runtime avoids Grok's child-process cleanup and update locks.
binary_hash=$(sha256sum "$binary" | cut -c1-12)
monitor_hash=$(sha256sum "$monitor_binary" | cut -c1-12)
runtime_dir="$grok_home/grok-budget/runtime/$expected_version-$binary_hash-$monitor_hash"
mkdir -p "$runtime_dir"
runtime_exe="$runtime_dir/grok-budget.exe"
runtime_monitor="$runtime_dir/grok-budget-monitor.exe"
if [ ! -f "$runtime_exe" ] || [ "$(sha256sum "$runtime_exe" | cut -d' ' -f1)" != "$(sha256sum "$binary" | cut -d' ' -f1)" ]; then
    cp "$binary" "$runtime_exe"
fi
if [ ! -f "$runtime_monitor" ]; then
    cp "$monitor_binary" "$runtime_monitor"
fi
chmod +x "$runtime_exe" "$runtime_monitor"

install_units() {
    unit_dir=$(grok_budget_unit_dir)
    mkdir -p "$unit_dir"
    grok_budget_stop_monitor_units
    grok_budget_wait_monitor_inactive 15 || return 1
    if ! grok_budget_monitor_service_text "$runtime_monitor" "$grok_home" > "$unit_dir/$GROK_BUDGET_MONITOR_SERVICE"; then
        return 1
    fi
    grok_budget_monitor_timer_text > "$unit_dir/$GROK_BUDGET_MONITOR_TIMER"
    systemctl --user daemon-reload || return 1
    # enable --now starts both: the service at login, the watchdog every minute.
    systemctl --user enable --now "$GROK_BUDGET_MONITOR_SERVICE" "$GROK_BUDGET_MONITOR_TIMER" || return 1
    grok_budget_wait_monitor_active 15 || return 1
}

units_installed=0
if [ "$systemd_ok" -eq 1 ]; then
    if ! install_units; then
        unit_dir=$(grok_budget_unit_dir)
        restored=0
        for unit in "$GROK_BUDGET_MONITOR_SERVICE" "$GROK_BUDGET_MONITOR_TIMER"; do
            if [ -f "$backup/$unit" ]; then
                cp "$backup/$unit" "$unit_dir/$unit"
                restored=1
            else
                rm -f "$unit_dir/$unit"
            fi
        done
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        if [ "$restored" -eq 1 ]; then
            systemctl --user start "$GROK_BUDGET_MONITOR_SERVICE" "$GROK_BUDGET_MONITOR_TIMER" >/dev/null 2>&1 || true
        fi
        echo 'Failed to install the systemd monitor units; previous units were restored.' >&2
        exit 1
    fi
    units_installed=1
fi

# Keep the existing launcher path, so already-open sessions pick up Rust immediately.
printf '#!/bin/sh\nexec "%s" --statusline --grok-home "%s"\n' "$runtime_exe" "$grok_home" > "$launcher"
chmod 0755 "$launcher"

toml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

update_status_line_config() {
    config=$1
    block=$2
    if [ ! -f "$config" ]; then
        printf '\n\n%s\n' "$block" > "$config"
        return 0
    fi
    tmp="$config.grok-budget.tmp"
    BLOCK="$block" awk '
        BEGIN { inblock = 0; replaced = 0; out = ""; block = ENVIRON["BLOCK"] }
        {
            if (inblock) {
                if ($0 ~ /^\[/) { inblock = 0 } else { next }
            }
            if (!replaced && $0 ~ /^\[ui\.status_line\]/) {
                out = out block "\n\n"
                inblock = 1; replaced = 1; next
            }
            out = out $0 "\n"
        }
        END {
            if (!replaced) {
                while (length(out) > 0 && substr(out, length(out), 1) == "\n") {
                    out = substr(out, 1, length(out) - 1)
                }
                out = out "\n\n" block "\n"
            }
            printf "%s", out
        }
    ' "$config" > "$tmp"
    if cmp -s "$config" "$tmp"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$config"
    fi
}

escaped_launcher=$(toml_escape "$launcher")
config_block="[ui.status_line]
type = \"command\"
command = \"$escaped_launcher\"
refresh_interval = 1"
update_status_line_config "$config_path" "$config_block"

echo "Installed native runtime: $runtime_exe"
if [ "$units_installed" -eq 1 ]; then
    echo "Monitor units: $GROK_BUDGET_MONITOR_SERVICE, $GROK_BUDGET_MONITOR_TIMER; automatic recovery every minute. Restart Grok to reload hooks."
else
    echo "Warning: no usable systemd user session, so the background monitor was not installed." >&2
    echo "Run '$runtime_monitor --daemon' or add your own service manager to refresh in the background." >&2
fi
echo "Rollback files: $backup"
if ! "$installed_abs/grok-budget.exe"; then
    echo "Installed successfully; quota query unavailable. Run: '$installed_abs/grok-budget.exe' --refresh" >&2
fi