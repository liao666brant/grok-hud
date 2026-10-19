#!/bin/sh
# Local HTTP tests for the GitHub bootstrap in install.sh. They cover missing
# package/checksum, checksum mismatch, extraction without executable bits, and
# replacing an existing source tree on a repeated run.
set -eu

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required for the bootstrap test.' >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/grok-hud-bootstrap-test.XXXXXX")
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
    echo "$1" >&2
    if [ -f "$tmp/run.out" ]; then
        sed 's/^/  /' "$tmp/run.out" >&2
    fi
    exit 1
}

test_bin="$tmp/bin"
serve="$tmp/serve"
pkg="$tmp/package"
grok_home="$tmp/grok-home"
installer="$tmp/install.sh"
marker="$tmp/marker"
mkdir -p "$test_bin" "$serve" "$grok_home"
cp "$repo_root/install.sh" "$installer"

cat > "$test_bin/grok" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$test_bin/cargo" <<EOF
#!/bin/sh
printf 'called\n' >> "$tmp/cargo-called"
exit 97
EOF
chmod +x "$test_bin/grok" "$test_bin/cargo"

cat > "$tmp/server.py" <<'PY'
import http.server
import sys

root, port_file = sys.argv[1:3]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(port_file, 'w', encoding='ascii') as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
port_file="$tmp/port"
python3 "$tmp/server.py" "$serve" "$port_file" >/dev/null 2>&1 &
server_pid=$!
i=0
while [ ! -s "$port_file" ]; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || fail 'The local HTTP server did not start.'
    kill -0 "$server_pid" 2>/dev/null || fail 'The local HTTP server exited.'
    sleep 0.1
done
base="http://127.0.0.1:$(cat "$port_file")"

build_package() {
    version=$1
    rm -rf "$pkg"
    rm -f "$serve/GrokHUD-linux-x64.zip" "$serve/GrokHUD-linux-x64.zip.sha256"
    mkdir -p "$pkg/grok-hud"
    cat > "$pkg/install.sh" <<'EOF'
#!/bin/sh
set -eu
root=$(cd -- "$(dirname -- "$0")" && pwd -P)
printf 'args=%s\n' "$*" >> "$GROK_HUD_TEST_MARKER"
printf 'script=%s\n' "$0" >> "$GROK_HUD_TEST_MARKER"
printf 'version=%s\n' "$(cat "$root/version.txt")" >> "$GROK_HUD_TEST_MARKER"
[ -x "$root/grok-hud/grok-hud.exe" ] || exit 20
[ -x "$root/grok-hud/grok-hud-monitor.exe" ] || exit 21
EOF
    cat > "$pkg/uninstall.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
    printf '%s\n' "$version" > "$pkg/version.txt"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$pkg/grok-hud/grok-hud.exe"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$pkg/grok-hud/grok-hud-monitor.exe"
    printf '{"name":"grok-hud","version":"%s"}\n' "$version" > "$pkg/grok-hud/plugin.json"
    # Store mode 0644 to mirror python3 -m zipfile extraction. The bootstrap
    # must restore executable bits before it execs the packaged installer.
    find "$pkg" -type f -exec chmod 0644 {} +
    python3 - "$pkg" "$serve/GrokHUD-linux-x64.zip" <<'PY'
import os
import sys
import zipfile

root, output = sys.argv[1:3]
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for directory, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        for name in filenames:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root).replace(os.sep, '/')
            info = zipfile.ZipInfo(relative)
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, 'rb') as handle:
                archive.writestr(info, handle.read())
PY
    hash=$(sha256sum "$serve/GrokHUD-linux-x64.zip" | cut -d' ' -f1)
    printf '%s  GrokHUD-linux-x64.zip\n' "$hash" > "$serve/GrokHUD-linux-x64.zip.sha256"
}

run_bootstrap() {
    url=$1
    rm -f "$marker"
    PATH="$test_bin:$PATH" \
    GROK_HOME="$grok_home" \
    GROK_HUD_RELEASE_URL="$url" \
    GROK_HUD_TEST_MARKER="$marker" \
    sh "$installer" >"$tmp/run.out" 2>&1
}

build_package 1.0.0
if run_bootstrap "$base/Missing.zip"; then
    fail 'A missing release package must fail.'
fi
grep -q 'Cannot download the Linux package' "$tmp/run.out" || fail 'A missing package must print download instructions.'
[ ! -e "$marker" ] || fail 'A missing package must not run the packaged installer.'
[ ! -e "$tmp/cargo-called" ] || fail 'A missing package must not invoke cargo.'

rm -f "$serve/GrokHUD-linux-x64.zip.sha256"
if run_bootstrap "$base/GrokHUD-linux-x64.zip"; then
    fail 'A missing checksum must fail.'
fi
grep -q 'Cannot download the release checksum' "$tmp/run.out" || fail 'A missing checksum must be reported.'
[ ! -e "$marker" ] || fail 'An unverified package must not run the packaged installer.'

build_package 1.0.0
printf '%064d  GrokHUD-linux-x64.zip\n' 0 > "$serve/GrokHUD-linux-x64.zip.sha256"
if run_bootstrap "$base/GrokHUD-linux-x64.zip"; then
    fail 'A checksum mismatch must fail.'
fi
grep -q 'Release checksum mismatch' "$tmp/run.out" || fail 'A checksum mismatch must be reported.'
[ ! -e "$marker" ] || fail 'A mismatched package must not run the packaged installer.'

build_package 1.0.0
run_bootstrap "$base/GrokHUD-linux-x64.zip" || fail 'A verified package must install.'
grep -qx 'args=--replace-source' "$marker" || fail 'The bootstrap must hand off to the packaged installer with --replace-source.'
grep -qx 'version=1.0.0' "$marker" || fail 'The packaged installer must run from the new source tree.'
[ -x "$grok_home/grok-hud/source/install.sh" ] || fail 'The packaged installer must be executable.'
[ -x "$grok_home/grok-hud/source/grok-hud/grok-hud.exe" ] || fail 'The packaged binary must be executable.'
[ -x "$grok_home/grok-hud/source/grok-hud/grok-hud-monitor.exe" ] || fail 'The packaged monitor must be executable.'
[ ! -e "$tmp/cargo-called" ] || fail 'A verified package must not invoke cargo.'

build_package 2.0.0
run_bootstrap "$base/GrokHUD-linux-x64.zip" || fail 'A repeated bootstrap run must install.'
grep -qx 'version=2.0.0' "$marker" || fail 'A repeated bootstrap run must update the source tree.'
grep -q '"version":"2.0.0"' "$grok_home/grok-hud/source/grok-hud/plugin.json" || fail 'The source tree must contain the new version.'
[ ! -e "$grok_home/grok-hud/source.previous" ] || fail 'The previous source tree must be removed after a successful swap.'

if run_bootstrap "$base/Missing.zip"; then
    fail 'A missing package must fail after an existing source tree.'
fi
grep -q '"version":"2.0.0"' "$grok_home/grok-hud/source/grok-hud/plugin.json" || fail 'A failed download must keep the existing source tree.'

echo 'Installer bootstrap download, checksum, extraction and source replacement tests passed.'
