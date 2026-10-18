#!/bin/sh
# Linux build pipeline: format, tests, Clippy, release build, shell syntax
# checks, monitor unit tests and packaging. Mirrors scripts/build.ps1.
set -eu

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
output_directory=${1:-$repo_root}

cd "$repo_root"
cargo fmt --all -- --check
cargo test --release --locked
cargo clippy --release --locked --all-targets -- -D warnings
cargo build --release --locked
for script in install.sh uninstall.sh scripts/*.sh tests/*.sh; do
    sh -n "$script"
done
sh tests/monitor-service.sh
sh scripts/package.sh "$output_directory"