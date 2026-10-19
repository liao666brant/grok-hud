#!/bin/sh
# Packages and verifies the linux-x64 distribution ZIP. Mirrors scripts/package.ps1.
set -eu

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
output_directory=${1:-$repo_root}
case "$output_directory" in
    /*) ;;
    *) output_directory="$repo_root/$output_directory" ;;
esac
cd "$repo_root"

version=$(jq -r '.version' grok-budget/plugin.json)
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo 'Expected a numeric release version.' >&2; exit 1; }
grep -Eq "^version = \"$version\"$" Cargo.toml || { echo 'Cargo and plugin versions differ.' >&2; exit 1; }
binary=target/release/grok-budget
monitor=target/release/grok-budget-monitor
[ -x "$binary" ] || { echo "Missing release binary: $binary (run scripts/build.sh first)." >&2; exit 1; }
[ -x "$monitor" ] || { echo "Missing release binary: $monitor (run scripts/build.sh first)." >&2; exit 1; }
binary_version=$("$binary" --version)
[ "$binary_version" = "grok-budget $version" ] || { echo 'Release binary and manifest versions differ.' >&2; exit 1; }
cp "$binary" grok-budget/grok-budget.exe
cp "$monitor" grok-budget/grok-budget-monitor.exe

files="Cargo.toml Cargo.lock rust-toolchain.toml README.md LICENSE CHANGELOG.md install.ps1 uninstall.ps1 install.sh uninstall.sh"
for f in $(find src tests scripts grok-budget -type f); do
    files="$files $f"
done
files=$(printf '%s\n' $files | LC_ALL=C sort -u)

# Ship executable modes inside the ZIP even when the checkout lost them.
chmod +x grok-budget/grok-budget.exe grok-budget/grok-budget-monitor.exe
chmod +x install.sh uninstall.sh scripts/*.sh tests/*.sh

name="GrokBudget-$version-linux-x64.zip"
staging="$repo_root/target/package/$(date +%s%N)"
temp_zip="$staging/$name"
mkdir -p "$staging" "$output_directory"
# Prefer Info-ZIP (the CI baseline). Linux-native 7-Zip also preserves Unix
# mode bits; the Windows build does not, which the extracted-mode check catches.
if command -v zip >/dev/null 2>&1; then
    (cd "$repo_root" && zip -q -X "$temp_zip" $files)
elif command -v 7zz >/dev/null 2>&1; then
    (cd "$repo_root" && 7zz a -tzip -bd -y -bso0 -bsp0 "$temp_zip" $files)
elif command -v 7z >/dev/null 2>&1; then
    (cd "$repo_root" && 7z a -tzip -bd -y -bso0 -bsp0 "$temp_zip" $files)
else
    echo 'zip or Linux-native 7-Zip (7zz/7z) is required.' >&2
    exit 1
fi

# Verify all packaged bytes, then smoke-test the extracted binary without any user data.
extracted="$staging/extracted"
mkdir -p "$extracted"
(cd "$extracted" && unzip -q "$temp_zip")
for relative in install.sh grok-budget/grok-budget.exe; do
    [ -x "$extracted/$relative" ] || {
        echo "Packaged file lost its executable bit: $relative (use zip or Linux-native 7-Zip)." >&2
        exit 1
    }
done
for relative in $files; do
    a=$(sha256sum "$relative" | cut -d' ' -f1)
    b=$(sha256sum "$extracted/$relative" | cut -d' ' -f1)
    [ "$a" = "$b" ] || { echo "Packaged file differs: $relative" >&2; exit 1; }
done
extracted_version=$("$extracted/grok-budget/grok-budget.exe" --version)
[ "$extracted_version" = "$binary_version" ] || { echo 'Extracted binary smoke test failed.' >&2; exit 1; }

output="$output_directory/$name"
mv "$temp_zip" "$output"
hash=$(sha256sum "$output" | cut -d' ' -f1)
printf '%s  %s\n' "$hash" "$name" > "$output.sha256"
count=$(printf '%s\n' $files | wc -l)
echo "Verified package: $output ($count files)"