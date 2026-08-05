#!/usr/bin/env bash
#
# Name and zip a gated object as a PIE pre-packaged-binary asset, then append
# ASSET=<path> to $GITHUB_ENV for the upload step.
#
# Usage: stage-asset.sh <out-dir> <stage-dir> <os> <libc>
#
# Reads TAG, MATRIX_PHP, MATRIX_TS and MATRIX_ARCH.

set -euo pipefail

out_dir="$1"
stage_dir="$2"
os="$3"
libc="$4"

fail() {
    echo "::error::$*"
    exit 1
}

abi="$(cat "$out_dir/php-abi")"
ts_suffix="$(cat "$out_dir/ts-suffix")"

# Cross-check the binary against the matrix. If a pinned image or a setup-php
# input were wrong, the asset would otherwise be published under a name that
# lies about its contents, and PIE would hand users an object built for a
# different PHP.
[ "$abi" = "$MATRIX_PHP" ] ||
    fail "Built PHP is $abi but the matrix says $MATRIX_PHP; the build environment is wrong."
if [ "$MATRIX_TS" = "zts" ]; then expected_suffix="-zts"; else expected_suffix=""; fi
[ "$ts_suffix" = "$expected_suffix" ] ||
    fail "Built PHP thread-safety '$ts_suffix' disagrees with matrix '$MATRIX_TS'."

case "$(uname -m)" in
x86_64) arch=x86_64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "Unsupported machine $(uname -m)." ;;
esac
[ "$arch" = "$MATRIX_ARCH" ] || fail "Runner reports $arch but the matrix says $MATRIX_ARCH."

# PIE's pre-packaged-binary method looks for, all lowercased:
#   php_{ext}-{version}_php{maj.min}-{arch}-{os}-{libc}[-zts].zip
# {version} is Composer's pretty version. Packagist reports this package as
# v1.13.1, so the v-prefixed tag goes in verbatim.
name="php_maxminddb-${TAG}_php${abi}-${arch}-${os}-${libc}${ts_suffix}.zip"
name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

mkdir -p "$stage_dir"
stage_dir="$(cd "$stage_dir" && pwd)" # absolute, because zip runs from out_dir
# -j so maxminddb.so lands at the archive root: PIE copies that one file out and
# installs nothing else.
( cd "$out_dir" && zip -j "$stage_dir/$name" maxminddb.so )

contents="$(unzip -Z1 "$stage_dir/$name")"
[ "$contents" = "maxminddb.so" ] ||
    fail "Archive must contain exactly maxminddb.so at its root, got: $contents"

echo "Staged $name"
echo "ASSET=$stage_dir/$name" >> "$GITHUB_ENV"
