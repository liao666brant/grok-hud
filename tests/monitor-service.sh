#!/bin/sh
# Monitor unit-definition, ELF binary and native exit-code tests. Add
# -Integration to also verify real systemd user recovery on a logged-in
# Linux session, mirroring tests/monitor-task.ps1.
set -eu

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$repo_root/scripts/monitor-service.sh"

integration=0
binary=""
while [ $# -gt 0 ]; do
    case "$1" in
        -Integration) integration=1 ;;
        -Binary) shift; binary=$1 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

fail() {
    echo "$1" >&2
    exit 1
}

fixture_exe="/test space/O'Brien/monitor.exe"
fixture_home="/test space/O'Brien/.grok"
service_text=$(grok_budget_monitor_service_text "$fixture_exe" "$fixture_home") || fail 'Unit arguments with a double quote must be rejected.'
printf '%s\n' "$service_text" | grep -qF "Description=$GROK_BUDGET_MONITOR_DESCRIPTION" || fail 'Service description must identify this installer.'
printf '%s\n' "$service_text" | grep -qF "ExecStart=\"$fixture_exe\" --grok-home \"$fixture_home\"" || fail 'ExecStart quoting must preserve spaces and apostrophes.'
printf '%s\n' "$service_text" | grep -qF 'Restart=on-failure' || fail 'Failure retries must remain enabled.'
printf '%s\n' "$service_text" | grep -qF 'WantedBy=default.target' || fail 'Monitor must start at login.'
timer_text=$(grok_budget_monitor_timer_text)
printf '%s\n' "$timer_text" | grep -qF 'OnCalendar=minutely' || fail 'Watchdog must run every minute.'
printf '%s\n' "$timer_text" | grep -qF 'WantedBy=timers.target' || fail 'Watchdog timer must be enabled with the user timers.'
if grok_budget_monitor_service_text 'bad"quote.exe' "$fixture_home" >/dev/null 2>&1; then
    fail 'A double quote in a unit path must be rejected.'
fi

tmpcfg=$(mktemp -d)
mkdir -p "$tmpcfg/systemd/user"
printf 'Description=Something else\n' > "$tmpcfg/systemd/user/$GROK_BUDGET_MONITOR_SERVICE"
if XDG_CONFIG_HOME="$tmpcfg" grok_budget_units_owned_by_us >/dev/null 2>&1; then
    fail 'A foreign unit description must be rejected.'
fi
printf 'Description=%s\n' "$GROK_BUDGET_MONITOR_DESCRIPTION" > "$tmpcfg/systemd/user/$GROK_BUDGET_MONITOR_SERVICE"
XDG_CONFIG_HOME="$tmpcfg" grok_budget_units_owned_by_us || fail 'Our own unit description must be accepted.'
rm -rf "$tmpcfg"

# Linux cargo output has no .exe suffix; -Binary can point at a packaged copy.
[ -n "$binary" ] || binary="$repo_root/target/release/grok-budget-monitor"
[ -f "$binary" ] || fail "Monitor binary not found: $binary"
binary=$(cd -- "$(dirname -- "$binary")" && pwd -P)/$(basename "$binary")
# The packaged monitor must be a Linux ELF binary, never a stray Windows build.
magic=$(head -c 4 "$binary" | od -An -tx1 | tr -d ' \n')
[ "$magic" = "7f454c46" ] || fail 'Monitor must be a Linux ELF binary.'
set +e
"$binary" --invalid-option >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'Native argument failure must produce a nonzero exit code.'
echo 'Monitor definition, ELF binary and native exit-code tests passed.'

[ "$integration" -eq 1 ] || exit 0
command -v systemctl >/dev/null 2>&1 || fail 'systemctl not available.'
systemctl --user show-environment >/dev/null 2>&1 || fail 'No systemd user session available.'

fixture_id=$(od -An -N8 -tx8 /dev/urandom | tr -d ' \n')
fixture_home="$repo_root/target/monitor-tests/$fixture_id"
mkdir -p "$fixture_home"
service="grok-budget-test-$fixture_id.service"
timer="grok-budget-test-$fixture_id.timer"
unit_dir=$(grok_budget_unit_dir)
registered=0

fixture_processes() {
    count=0
    for proc in /proc/[0-9]*; do
        [ -r "$proc/exe" ] || continue
        exe=$(readlink "$proc/exe" 2>/dev/null || true)
        [ "$exe" = "$binary" ] || continue
        cmd=$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)
        case "$cmd" in
            *"$fixture_home"*) count=$((count + 1)) ;;
        esac
    done
    echo "$count"
}

wait_fixture_active() {
    end=$(( $(date +%s) + ${1:-15} ))
    while [ "$(date +%s)" -lt "$end" ]; do
        state=$(systemctl --user is-active "$service" 2>/dev/null || true)
        if [ "$state" = "active" ]; then
            sleep 1
            state=$(systemctl --user is-active "$service" 2>/dev/null || true)
            [ "$state" = "active" ] && return 0
        fi
        sleep 1
    done
    return 1
}

cleanup() {
    if [ "$registered" -eq 1 ]; then
        systemctl --user stop "$timer" "$service" >/dev/null 2>&1 || true
        systemctl --user disable "$timer" "$service" >/dev/null 2>&1 || true
        rm -f "$unit_dir/$service" "$unit_dir/$timer"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

grok_budget_monitor_service_text "$binary" "$fixture_home" > "$unit_dir/$service"
grok_budget_monitor_timer_text > "$unit_dir/$timer"
systemctl --user daemon-reload
registered=1
systemctl --user start "$service"
wait_fixture_active 15 || fail 'Test service did not stay running.'
[ "$(fixture_processes)" -eq 1 ] || fail 'Must launch exactly one native monitor.'
systemctl --user start "$timer"
systemctl --user start "$service"
systemctl --user start "$service"
systemctl --user start "$service"
sleep 2
[ "$(fixture_processes)" -eq 1 ] || fail 'Repeated starts created duplicate monitors.'
systemctl --user stop "$service"
end=$(( $(date +%s) + 15 ))
while [ "$(fixture_processes)" -gt 0 ] && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
[ "$(fixture_processes)" -eq 0 ] || fail 'Stopping the service did not stop its native child.'
echo 'Stopped the isolated monitor; waiting for its automatic one-minute restart.'
wait_fixture_active 80 || fail 'Watchdog failed to restore one monitor.'
[ "$(fixture_processes)" -eq 1 ] || fail 'Watchdog restored more than one monitor.'
echo 'Real systemd user recovery and single-instance tests passed.'