# Linux data migration helpers shared by install.sh and tests/migrate-data.sh.

# Copy entries that do not exist in the destination yet. Used for old backup
# snapshots, so a fresh backup is never overwritten by an older one.
grok_hud_copy_missing_tree() {
    src=$1
    dst=$2
    mkdir -p "$dst" || return 1
    for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
        [ -e "$entry" ] || continue
        name=${entry##*/}
        if [ -d "$entry" ] && [ ! -L "$entry" ]; then
            grok_hud_copy_missing_tree "$entry" "$dst/$name" || return 1
        elif [ ! -e "$dst/$name" ]; then
            cp -pR "$entry" "$dst/$name" || return 1
        fi
    done
    return 0
}

# Copy the complete legacy data directory. The database and its WAL/SHM files
# move together; a database copied alone can lose the most recent history.
grok_hud_copy_legacy_data() {
    legacy=$1
    target=$2
    [ -d "$legacy" ] || return 0
    mkdir -p "$target" || return 1
    copy_db=0
    copy_sidecars=0
    if [ -f "$legacy/history.sqlite3" ]; then
        if [ ! -s "$target/history.sqlite3" ]; then
            copy_db=1
            copy_sidecars=1
        elif cmp -s "$target/history.sqlite3" "$legacy/history.sqlite3" && [ ! -s "$target/history.sqlite3-wal" ]; then
            # A previous install may have copied only the database. If the
            # target has no WAL yet, the legacy sidecars still belong to it.
            copy_sidecars=1
        fi
    fi
    if [ "$copy_db" -eq 1 ]; then
        cp -p "$legacy/history.sqlite3" "$target/history.sqlite3" || return 1
    fi
    if [ "$copy_sidecars" -eq 1 ]; then
        for name in history.sqlite3-wal history.sqlite3-shm history.sqlite3-journal; do
            if [ -f "$legacy/$name" ]; then
                cp -p "$legacy/$name" "$target/$name" || return 1
            fi
        done
    fi
    for entry in "$legacy"/* "$legacy"/.[!.]* "$legacy"/..?*; do
        [ -e "$entry" ] || continue
        name=${entry##*/}
        case "$name" in
            history.sqlite3|history.sqlite3-wal|history.sqlite3-shm|history.sqlite3-journal|runtime|source|statusline.sh) continue ;;
        esac
        if [ "$name" = backups ]; then
            grok_hud_copy_missing_tree "$entry" "$target/backups" || return 1
        elif [ ! -e "$target/$name" ]; then
            cp -pR "$entry" "$target/$name" || return 1
        fi
    done
    return 0
}
