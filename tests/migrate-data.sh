#!/bin/sh
# Tests for the legacy data copy shared by install.sh.
set -eu

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$repo_root/scripts/migrate-data.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/grok-hud-migrate-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
    echo "$1" >&2
    exit 1
}

assert_content() {
    [ -f "$1" ] || fail "Missing file: $1"
    [ "$(cat "$1")" = "$2" ] || fail "Unexpected content in $1"
}

assert_absent() {
    [ ! -e "$1" ] || fail "Unexpected path: $1"
}

# A pre-created target (the bootstrap creates its source directory there) must
# still receive the database, WAL/SHM, old backups and other files.
legacy="$tmp/legacy"
target="$tmp/target"
mkdir -p "$legacy/backups/20260101-000000" "$legacy/runtime" "$legacy/source" \
    "$target/backups/20260202-000000" "$target/source"
printf 'database' > "$legacy/history.sqlite3"
printf 'wal' > "$legacy/history.sqlite3-wal"
printf 'shm' > "$legacy/history.sqlite3-shm"
printf 'journal' > "$legacy/history.sqlite3-journal"
printf 'old backup' > "$legacy/backups/20260101-000000/snapshot.txt"
printf 'new backup' > "$target/backups/20260202-000000/snapshot.txt"
printf 'notes' > "$legacy/notes.txt"
printf 'hidden' > "$legacy/.hidden"
printf 'old runtime' > "$legacy/runtime/old.exe"
printf 'old launcher' > "$legacy/statusline.sh"
printf 'old source' > "$legacy/source/old.txt"
printf 'current source' > "$target/source/current.txt"

grok_hud_copy_legacy_data "$legacy" "$target" || fail 'Legacy data copy failed.'
assert_content "$target/history.sqlite3" 'database'
assert_content "$target/history.sqlite3-wal" 'wal'
assert_content "$target/history.sqlite3-shm" 'shm'
assert_content "$target/history.sqlite3-journal" 'journal'
assert_content "$target/notes.txt" 'notes'
assert_content "$target/.hidden" 'hidden'
assert_content "$target/backups/20260101-000000/snapshot.txt" 'old backup'
assert_content "$target/backups/20260202-000000/snapshot.txt" 'new backup'
assert_content "$target/source/current.txt" 'current source'
assert_absent "$target/runtime"
assert_absent "$target/statusline.sh"
assert_absent "$target/source/old.txt"

# A different target database wins; its missing WAL must not be filled from an
# unrelated legacy database.
legacy2="$tmp/legacy2"
target2="$tmp/target2"
mkdir -p "$legacy2" "$target2"
printf 'legacy database' > "$legacy2/history.sqlite3"
printf 'legacy wal' > "$legacy2/history.sqlite3-wal"
printf 'target database' > "$target2/history.sqlite3"
grok_hud_copy_legacy_data "$legacy2" "$target2" || fail 'Legacy data merge failed.'
assert_content "$target2/history.sqlite3" 'target database'
assert_absent "$target2/history.sqlite3-wal"

# If an earlier install copied only the database, an identical target database
# means the WAL/SHM sidecars still belong to it and must be recovered.
legacy3="$tmp/legacy3"
target3="$tmp/target3"
mkdir -p "$legacy3" "$target3"
printf 'same database' > "$legacy3/history.sqlite3"
printf 'recent wal' > "$legacy3/history.sqlite3-wal"
printf 'recent shm' > "$legacy3/history.sqlite3-shm"
printf 'same database' > "$target3/history.sqlite3"
grok_hud_copy_legacy_data "$legacy3" "$target3" || fail 'WAL recovery failed.'
assert_content "$target3/history.sqlite3-wal" 'recent wal'
assert_content "$target3/history.sqlite3-shm" 'recent shm'

# If the target already has its own WAL, keep it instead of replacing newer
# history with the legacy sidecar.
legacy3b="$tmp/legacy3b"
target3b="$tmp/target3b"
mkdir -p "$legacy3b" "$target3b"
printf 'same database' > "$legacy3b/history.sqlite3"
printf 'legacy wal' > "$legacy3b/history.sqlite3-wal"
printf 'same database' > "$target3b/history.sqlite3"
printf 'target wal' > "$target3b/history.sqlite3-wal"
grok_hud_copy_legacy_data "$legacy3b" "$target3b" || fail 'Existing WAL preservation failed.'
assert_content "$target3b/history.sqlite3-wal" 'target wal'

# A missing target is created and all retained files are copied.
legacy4="$tmp/legacy4"
target4="$tmp/target4"
mkdir -p "$legacy4/backups/old"
printf 'db' > "$legacy4/history.sqlite3"
mkdir -p "$legacy4/runtime"
printf 'runtime' > "$legacy4/runtime/monitor"
printf 'snapshot' > "$legacy4/backups/old/data"
grok_hud_copy_legacy_data "$legacy4" "$target4" || fail 'Copy to a missing target failed.'
assert_content "$target4/history.sqlite3" 'db'
assert_content "$target4/backups/old/data" 'snapshot'
assert_absent "$target4/runtime"

echo 'Legacy data migration tests passed.'
