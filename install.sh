#!/bin/sh
# Linux installer. Registers the plugin, wires the status line, and installs
# systemd user units for the background monitor. Mirrors install.ps1.
# It runs from a checkout or a distribution folder. When piped from GitHub it
# downloads and verifies the current Linux release package.
set -eu

usage() {
    cat >&2 <<'EOF'
Usage: ./install.sh [--build] [--replace-source]
       curl -fsSL https://raw.githubusercontent.com/liao666brant/grok-hud/main/install.sh | sh
EOF
    exit 1
}

build=0
replace_source=0
for arg in "$@"; do
    case "$arg" in
        --build) build=1 ;;
        --replace-source) replace_source=1 ;;
        *) usage ;;
    esac
done

script_dir=$(dirname -- "$0")
repo_root=''
if [ -f "$script_dir/grok-hud/plugin.json" ] && [ -f "$script_dir/scripts/monitor-service.sh" ]; then
    repo_root=$(cd -- "$script_dir" && pwd -P)
fi

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

command -v grok >/dev/null 2>&1 || { echo 'grok CLI not found on PATH.' >&2; exit 1; }

fetch_file() {
    url=$1
    destination=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --max-time 300 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 300 -O "$destination" "$url"
    else
        echo 'curl or wget is required for the GitHub installer.' >&2
        return 1
    fi
}

extract_zip() {
    archive=$1
    destination=$2
    mkdir -p "$destination"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$archive" -d "$destination"
    elif command -v 7zz >/dev/null 2>&1; then
        7zz x -bd -y -bso0 -bsp0 -o"$destination" "$archive" >/dev/null
    elif command -v 7z >/dev/null 2>&1; then
        7z x -bd -y -bso0 -bsp0 -o"$destination" "$archive" >/dev/null
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$archive" -C "$destination"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m zipfile -e "$archive" "$destination"
    else
        echo 'unzip, 7-Zip, bsdtar, or python3 is required to extract the release.' >&2
        return 1
    fi
}

bootstrap_from_github() {
    source_root="$grok_home/grok-hud/source"
    release_url=${GROK_HUD_RELEASE_URL:-https://github.com/liao666brant/grok-hud/releases/latest/download/GrokHUD-linux-x64.zip}
    work=$(mktemp -d "${TMPDIR:-/tmp}/grok-hud-install.XXXXXX")
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    archive="$work/GrokHUD-linux-x64.zip"

    if ! fetch_file "$release_url" "$archive"; then
        cat >&2 <<EOF
Cannot download the Linux package from the latest GitHub release:
  $release_url

The release may not include a Linux package yet, or the network request failed.
Download the ZIP from https://github.com/liao666brant/grok-hud/releases/latest,
extract it, and run ./install.sh in the extracted directory.
EOF
        return 1
    fi

    if ! fetch_file "$release_url.sha256" "$archive.sha256"; then
        cat >&2 <<EOF
Cannot download the release checksum:
  $release_url.sha256

Refusing to install an unverified package. Download the ZIP and its .sha256
file from https://github.com/liao666brant/grok-hud/releases/latest, verify the
archive, extract it, and run ./install.sh in the extracted directory.
EOF
        return 1
    fi
    expected=$(cut -d' ' -f1 "$archive.sha256" | head -n 1)
    if ! printf '%s\n' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$'; then
        echo 'The release checksum file is malformed.' >&2
        return 1
    fi
    actual=$(sha256sum "$archive" | cut -d' ' -f1)
    if [ "$expected" != "$actual" ]; then
        echo 'Release checksum mismatch.' >&2
        return 1
    fi

    extract_zip "$archive" "$work/source" || return 1
    [ -f "$work/source/grok-hud/plugin.json" ] || {
        echo 'The downloaded package does not contain the plugin.' >&2
        return 1
    }
    # python3 -m zipfile does not restore Unix modes. Make the entry points
    # executable regardless of which extractor handled the archive.
    for relative in install.sh uninstall.sh grok-hud/grok-hud.exe grok-hud/grok-hud-monitor.exe; do
        [ -f "$work/source/$relative" ] && chmod +x "$work/source/$relative"
    done

    mkdir -p "$grok_home/grok-hud"
    previous="$source_root.previous"
    rm -rf "$previous"
    if [ -d "$source_root" ]; then
        mv "$source_root" "$previous"
    fi
    if ! mv "$work/source" "$source_root"; then
        if [ -d "$previous" ]; then mv "$previous" "$source_root"; fi
        echo 'Cannot publish the downloaded package.' >&2
        return 1
    fi
    rm -rf "$previous" "$work"
    trap - EXIT HUP INT TERM
    echo "Installing from $source_root"
    exec "$source_root/install.sh" --replace-source "$@"
}

if [ -z "$repo_root" ]; then
    bootstrap_from_github "$@"
fi

plugin_source="$repo_root/grok-hud"
binary="$plugin_source/grok-hud.exe"
monitor_binary="$plugin_source/grok-hud-monitor.exe"

command -v jq >/dev/null 2>&1 || { echo 'jq is required but not on PATH.' >&2; exit 1; }
. "$repo_root/scripts/monitor-service.sh"
. "$repo_root/scripts/migrate-data.sh"

# Build when requested, or when the packaged binaries are missing or lost
# their executable bit (a git checkout without the mode records it nowhere).
if [ "$build" -eq 1 ] || [ ! -x "$binary" ] || [ ! -x "$monitor_binary" ]; then
    (cd "$repo_root" && cargo build --release --locked)
    cp "$repo_root/target/release/grok-hud" "$binary"
    cp "$repo_root/target/release/grok-hud-monitor" "$monitor_binary"
fi
chmod +x "$binary" "$monitor_binary"

grok plugin validate "$plugin_source" || { echo 'Plugin validation failed.' >&2; exit 1; }

plugin_list=$(grok plugin list --json)
plugin_field() {
    printf '%s' "$plugin_list" | jq -r "[.[]? | select(.name? == \"grok-hud\")][0].$1 // \"\""
}
legacy_field() {
    printf '%s' "$plugin_list" | jq -r "[.[]? | select(.name? == \"grok-budget\")][0].$1 // \"\""
}
existing_source=$(plugin_field 'source')
existing_path=$(plugin_field 'path')
legacy_source=$(legacy_field 'source')
legacy_path=$(legacy_field 'path')

expected_version=$(jq -r '.version' "$plugin_source/plugin.json")
binary_version=$("$binary" --version)
[ "$binary_version" = "grok-hud $expected_version" ] || { echo 'Manifest and executable versions differ.' >&2; exit 1; }

source_replacement=0
if [ -n "$existing_source" ]; then
    if [ -d "$existing_source" ]; then
        old_source=$(cd -- "$existing_source" && pwd -P)
    else
        old_source=$existing_source
    fi
    if [ "$old_source" != "$plugin_source" ]; then
        if [ "$replace_source" -eq 1 ]; then
            source_replacement=1
        else
            echo "Existing plugin comes from another directory: $old_source" >&2
            echo 'Re-run with --replace-source to register this directory instead.' >&2
            exit 1
        fi
    fi
fi

data_dir="$grok_home/grok-hud"
legacy_data="$grok_home/grok-budget"
systemd_ok=0
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemd_ok=1
fi

if [ "$systemd_ok" -eq 1 ]; then
    grok_hud_legacy_units_owned_by_us || exit 1
fi

legacy_present=0
legacy_plugin_present=0
legacy_units_present=0
new_plugin_present=0
if [ -n "$legacy_source" ] || [ -n "$legacy_path" ] || [ -d "$legacy_data" ]; then
    legacy_present=1
fi
if [ -n "$legacy_source" ] || [ -n "$legacy_path" ]; then
    legacy_plugin_present=1
fi
if [ -n "$existing_source" ]; then
    new_plugin_present=1
fi
if [ "$systemd_ok" -eq 1 ]; then
    unit_dir=$(grok_hud_unit_dir)
    for unit in "$GROK_HUD_LEGACY_MONITOR_SERVICE" "$GROK_HUD_LEGACY_MONITOR_TIMER"; do
        if [ -f "$unit_dir/$unit" ]; then legacy_units_present=1; fi
    done
fi

install_complete=0
legacy_disabled_by_installer=0
restore_legacy_on_failure() {
    [ "$install_complete" -eq 0 ] || return 0
    [ "$legacy_disabled_by_installer" -eq 1 ] || return 0
    if [ "$legacy_units_present" -eq 1 ]; then
        grok_hud_enable_legacy_units >/dev/null 2>&1 || true
    fi
    if [ "$legacy_plugin_present" -eq 1 ]; then
        grok plugin enable grok-budget >/dev/null 2>&1 || true
    fi
    if [ "$new_plugin_present" -eq 0 ]; then
        grok plugin disable grok-hud >/dev/null 2>&1 || true
    fi
}
trap restore_legacy_on_failure EXIT
trap 'restore_legacy_on_failure; exit 1' HUP INT TERM

# Back up BEFORE disabling or removing the legacy installation or touching the
# new one. The backup directory lives under the new data directory; creating it
# is safe because the legacy data is copied below instead of moved.
stamp=$(date +%Y%m%d-%H%M%S%3N)
backup="$data_dir/backups/$stamp"
mkdir -p "$backup"
config_path="$grok_home/config.toml"
launcher="$data_dir/statusline.sh"
for file in "$config_path" "$launcher" "$grok_home/installed-plugins/registry.json"; do
    if [ -f "$file" ]; then cp "$file" "$backup/"; fi
done
if [ "$new_plugin_present" -eq 1 ] && [ -n "$existing_path" ] && [ -d "$existing_path" ]; then
    cp -R "$existing_path" "$backup/previous-plugin"
fi
if [ "$legacy_plugin_present" -eq 1 ] && [ -n "$legacy_path" ] && [ -d "$legacy_path" ]; then
    cp -R "$legacy_path" "$backup/legacy-plugin"
fi
if [ -f "$legacy_data/statusline.sh" ]; then
    cp "$legacy_data/statusline.sh" "$backup/legacy-statusline.sh"
fi
if [ "$systemd_ok" -eq 1 ]; then
    unit_dir=$(grok_hud_unit_dir)
    for unit in "$GROK_HUD_MONITOR_SERVICE" "$GROK_HUD_MONITOR_TIMER"; do
        if [ -f "$unit_dir/$unit" ]; then cp "$unit_dir/$unit" "$backup/$unit"; fi
    done
    if [ "$legacy_units_present" -eq 1 ]; then
        mkdir -p "$backup/legacy-monitor-units"
        for unit in "$GROK_HUD_LEGACY_MONITOR_SERVICE" "$GROK_HUD_LEGACY_MONITOR_TIMER"; do
            if [ -f "$unit_dir/$unit" ]; then cp "$unit_dir/$unit" "$backup/legacy-monitor-units/$unit"; fi
        done
    fi
fi

# Stop the old monitor before copying its database, but keep its units, task,
# plugin and data in place until the replacement monitor has been verified.
legacy_monitor_stopped=0
if [ "$legacy_units_present" -eq 1 ]; then
    grok_hud_disable_legacy_units || { echo 'Failed to stop the legacy monitor units.' >&2; exit 1; }
    legacy_monitor_stopped=1
    legacy_disabled_by_installer=1
fi
if [ "$legacy_plugin_present" -eq 1 ]; then
    grok plugin disable grok-budget >/dev/null 2>&1 || true
    legacy_disabled_by_installer=1
fi
if [ -d "$legacy_data" ]; then
    if ! grok_hud_copy_legacy_data "$legacy_data" "$data_dir"; then
        if [ "$legacy_monitor_stopped" -eq 1 ]; then
            grok_hud_enable_legacy_units >/dev/null 2>&1 || true
        fi
        if [ "$legacy_plugin_present" -eq 1 ]; then
            grok plugin enable grok-budget >/dev/null 2>&1 || true
        fi
        echo 'Failed to migrate the legacy data directory.' >&2
        exit 1
    fi
fi
if [ "$legacy_present" -eq 1 ]; then
    plugin_list=$(grok plugin list --json)
    existing_source=$(plugin_field 'source')
    existing_path=$(plugin_field 'path')
fi

if [ "$source_replacement" -eq 1 ]; then
    # The caller explicitly accepted a new source directory. Backups are already
    # in place, so re-register instead of trying to update from the old path.
    grok plugin uninstall grok-hud --confirm --keep-data || {
        echo 'Existing plugin uninstall failed.' >&2
        exit 1
    }
    plugin_list=$(grok plugin list --json)
    existing_source=$(plugin_field 'source')
    existing_path=$(plugin_field 'path')
fi

if [ -n "$existing_source" ]; then
    grok plugin update grok-hud
    plugin_list=$(grok plugin list --json)
    registered_version=$(plugin_field 'version')
    registered_source=$(plugin_field 'source')
    if [ "$registered_version" != "$expected_version" ] || [ "$registered_source" != "$plugin_source" ]; then
        # Local update is a no-op in Grok 1.0.41. Re-register via the official CLI.
        # Keep already-open status lines usable while the copied plugin is replaced.
        rollback_exe="$backup/previous-plugin/grok-hud.exe"
        if [ -f "$rollback_exe" ]; then
            printf '#!/bin/sh\nexec "%s" --statusline\n' "$rollback_exe" > "$launcher"
            chmod 0755 "$launcher"
        fi
        grok plugin uninstall grok-hud --confirm --keep-data
        grok plugin install "$plugin_source" --trust
    fi
else
    grok plugin install "$plugin_source" --trust
fi
grok plugin enable grok-hud

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
    for relative in grok-hud.exe grok-hud-monitor.exe plugin.json hooks/hooks.json commands/budget.md report.html; do
        publish_file "$plugin_source/$relative" "$installed_abs/$relative"
    done
    chmod +x "$installed_abs/grok-hud.exe" "$installed_abs/grok-hud-monitor.exe"
fi
"$installed_abs/grok-hud.exe" --version >/dev/null || { echo 'Installed Rust binary failed validation.' >&2; exit 1; }

# A versioned independent runtime avoids Grok's child-process cleanup and update locks.
binary_hash=$(sha256sum "$binary" | cut -c1-12)
monitor_hash=$(sha256sum "$monitor_binary" | cut -c1-12)
runtime_dir="$data_dir/runtime/$expected_version-$binary_hash-$monitor_hash"
mkdir -p "$runtime_dir"
runtime_exe="$runtime_dir/grok-hud.exe"
runtime_monitor="$runtime_dir/grok-hud-monitor.exe"
if [ ! -f "$runtime_exe" ] || [ "$(sha256sum "$runtime_exe" | cut -d' ' -f1)" != "$(sha256sum "$binary" | cut -d' ' -f1)" ]; then
    cp "$binary" "$runtime_exe"
fi
if [ ! -f "$runtime_monitor" ]; then
    cp "$monitor_binary" "$runtime_monitor"
fi
chmod +x "$runtime_exe" "$runtime_monitor"

install_units() {
    unit_dir=$(grok_hud_unit_dir)
    mkdir -p "$unit_dir"
    grok_hud_stop_monitor_units
    grok_hud_wait_monitor_inactive 15 || return 1
    if ! grok_hud_monitor_service_text "$runtime_monitor" "$grok_home" > "$unit_dir/$GROK_HUD_MONITOR_SERVICE"; then
        return 1
    fi
    grok_hud_monitor_timer_text > "$unit_dir/$GROK_HUD_MONITOR_TIMER"
    systemctl --user daemon-reload || return 1
    # enable --now starts both: the service at login, the watchdog every minute.
    systemctl --user enable --now "$GROK_HUD_MONITOR_SERVICE" "$GROK_HUD_MONITOR_TIMER" || return 1
    grok_hud_wait_monitor_active 15 || return 1
}

units_installed=0
if [ "$systemd_ok" -eq 1 ]; then
    if ! install_units; then
        unit_dir=$(grok_hud_unit_dir)
        grok_hud_stop_monitor_units
        restored=0
        for unit in "$GROK_HUD_MONITOR_SERVICE" "$GROK_HUD_MONITOR_TIMER"; do
            if [ -f "$backup/$unit" ]; then
                cp "$backup/$unit" "$unit_dir/$unit"
                restored=1
            else
                rm -f "$unit_dir/$unit"
            fi
        done
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        if [ "$restored" -eq 1 ]; then
            systemctl --user enable "$GROK_HUD_MONITOR_TIMER" "$GROK_HUD_MONITOR_SERVICE" >/dev/null 2>&1 || true
            systemctl --user start "$GROK_HUD_MONITOR_TIMER" "$GROK_HUD_MONITOR_SERVICE" >/dev/null 2>&1 || true
        fi
        legacy_restored=0
        if [ "$legacy_units_present" -eq 1 ]; then
            grok_hud_enable_legacy_units >/dev/null 2>&1 && legacy_restored=1
        fi
        if [ "$legacy_plugin_present" -eq 1 ]; then
            grok plugin enable grok-budget >/dev/null 2>&1 || true
            if [ "$new_plugin_present" -eq 0 ]; then
                grok plugin disable grok-hud >/dev/null 2>&1 || true
            fi
        fi
        if [ "$restored" -eq 1 ]; then
            echo 'Failed to install the systemd monitor units; previous Grok HUD units were restored.' >&2
        elif [ "$legacy_restored" -eq 1 ]; then
            echo 'Failed to install the systemd monitor units; the legacy monitor units were restored.' >&2
        elif [ "$legacy_units_present" -eq 1 ]; then
            echo "Failed to install the systemd monitor units; the legacy units could not be restarted. See $backup." >&2
        else
            echo 'Failed to install the systemd monitor units; no previous monitor units were available.' >&2
        fi
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
    tmp="$config.grok-hud.tmp"
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

remove_legacy_plugin_entry() {
    config=$1
    [ -f "$config" ] || return 0
    tmp="$config.grok-hud.plugins.tmp"
    rc=0
    awk '
        BEGIN { in_plugins = 0; in_disabled = 0; removed = 0 }
        /^\[plugins\]$/ { in_plugins = 1 }
        in_plugins && /^disabled = \[$/ { in_disabled = 1 }
        in_disabled && $0 ~ /^[[:space:]]*"grok-budget",?[[:space:]]*$/ { removed = 1; next }
        in_disabled && /^\]/ { in_disabled = 0 }
        { print }
        END { exit (removed ? 0 : 2) }
    ' "$config" > "$tmp" || rc=$?
    if [ "$rc" -eq 0 ]; then
        cp "$config" "$backup/config-with-legacy-entry.toml"
        mv "$tmp" "$config"
    else
        rm -f "$tmp"
    fi
}

escaped_launcher=$(toml_escape "$launcher")
config_block="[ui.status_line]
type = \"command\"
command = \"$escaped_launcher\"
refresh_interval = 1"
update_status_line_config "$config_path" "$config_block"
install_complete=1

# The replacement monitor is verified. Now remove the old installation and its
# data. Failures here leave the legacy installation disabled and preserved.
if [ "$legacy_present" -eq 1 ]; then
    cleanup_failed=0
    if [ "$legacy_units_present" -eq 1 ] && [ "$systemd_ok" -eq 1 ]; then
        grok_hud_remove_legacy_units || cleanup_failed=1
    fi
    if [ "$legacy_plugin_present" -eq 1 ]; then
        if grok plugin uninstall grok-budget --confirm --keep-data; then
            remove_legacy_plugin_entry "$config_path"
        else
            cleanup_failed=1
        fi
    fi
    if [ "$cleanup_failed" -eq 0 ] && [ -d "$legacy_data" ]; then
        rm -rf "$legacy_data"
    fi
    if [ "$cleanup_failed" -ne 0 ]; then
        echo 'New installation is active, but some legacy grok-budget files could not be removed.' >&2
        echo 'The legacy monitor and plugin remain disabled; retry the installer or remove them manually.' >&2
    fi
fi
if [ "$legacy_plugin_present" -eq 0 ]; then
    remove_legacy_plugin_entry "$config_path"
fi

echo "Installed native runtime: $runtime_exe"
if [ "$units_installed" -eq 1 ]; then
    echo "Monitor units: $GROK_HUD_MONITOR_SERVICE, $GROK_HUD_MONITOR_TIMER; automatic recovery every minute. Restart Grok to reload hooks."
else
    echo "Warning: no usable systemd user session, so the background monitor was not installed." >&2
    echo "Run '$runtime_monitor --daemon' or add your own service manager to refresh in the background." >&2
fi
echo "Rollback files: $backup"
if ! "$installed_abs/grok-hud.exe"; then
    echo "Installed successfully; quota query unavailable. Run: '$installed_abs/grok-hud.exe' --refresh" >&2
fi
