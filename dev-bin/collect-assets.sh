#!/usr/bin/env bash
#
# Collect one release asset out of each staged artifact directory and assert
# that the set is complete. Run by verify-assets on every run, and again by
# publish immediately before it uploads, so a pull request exercises the same
# assertion a release depends on.
#
# Usage: collect-assets.sh <dist-dir> <assets-dir>
#
# Reads TAG, PHP_VERSIONS, TS_MODES, LINUX_ARCHES, LINUX_EXCLUDE and
# WINDOWS_MATRIX.

set -euo pipefail

dist="$1"
assets="$2"

# shellcheck source=dev-bin/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

find "$dist" -type f | sort

# Every build job stages exactly one file at its artifact root. The Windows
# action additionally stages a logs/ subdirectory, so select only files one
# level below an artifact directory and leave the logs out of the release.
mkdir -p "$assets"
find "$dist" -mindepth 2 -maxdepth 2 -type f -exec cp -t "$assets/" {} +

staged="$(find "$dist" -mindepth 2 -maxdepth 2 -type f | wc -l)"
collected="$(find "$assets" -maxdepth 1 -type f | wc -l)"
[ "$staged" -eq "$collected" ] ||
    fail "Two artifacts contain the same filename ($staged staged, $collected collected)."

# php-windows-builder drops a PHP version it does not support from the matrix
# without a message, and the checks below trust the matrix.
jq -e --argjson want "$PHP_VERSIONS" \
    '[.include[]."php-version"] | unique == ($want | unique)' \
    <<<"${WINDOWS_MATRIX:?}" >/dev/null ||
    fail "The Windows matrix does not build exactly the PHP versions $PHP_VERSIONS."

windows_count="$(jq '.include | length' <<<"$WINDOWS_MATRIX")"

php_count="$(jq 'length' <<<"$PHP_VERSIONS")"
ts_count="$(jq 'length' <<<"$TS_MODES")"
arch_count="$(jq 'length' <<<"$LINUX_ARCHES")"
# Each entry is a php and ts pair that Linux skips on every arch. setup keeps
# only the pairs that match a leg.
exclude_count="$(jq 'length' <<<"${LINUX_EXCLUDE:?}")"
# Linux (php x ts x arch, minus the exclusions) + macOS (php x ts).
binary_count=$(((php_count * ts_count - exclude_count) * arch_count + php_count * ts_count))

# 1 source tarball + the binary lanes + one zip for each leg of the Windows
# matrix. The other lists come from setup, which is also what each matrix
# expands, so the expectation cannot drift from what was built -- including when
# setup hands out the reduced pull-request lists. The Windows matrix comes from
# windows-matrix, and the check above holds it to setup's PHP versions.
expected=$((1 + binary_count + windows_count))

echo "Expecting $expected assets, found $collected:"
find "$assets" -maxdepth 1 -type f -printf '  %f\n' | sort

# This assertion is the point of the job. A release that silently ships the
# source tarball and zero binaries -- because an artifact glob matched nothing
# -- looks successful and is not.
[ "$collected" -eq "$expected" ] ||
    fail "Expected $expected release assets but found $collected. Refusing to publish a partial release."

# Named explicitly because every platform without a prebuilt binary depends on
# this one file.
[ -f "$assets/maxminddb-${TAG}.tgz" ] ||
    fail "$assets/maxminddb-${TAG}.tgz is missing."

# PIE downloads a Windows zip only by its exact name, which has the tag in it.
# It then loads the DLL in the zip by the same name. The matrix does not give
# the compiler, so accept any.
legs="$(jq -r '.include[] | [."php-version", .ts, .arch] | @tsv' <<<"$WINDOWS_MATRIX")"
while IFS=$'\t' read -r php ts arch; do
    if [ "$arch" = x64 ]; then
        arch=x86_64
    fi
    name="php_maxminddb-${TAG}-${php}-${ts}-vs*-${arch}.zip"
    matches=("$assets"/php_maxminddb-"$TAG"-"$php"-"$ts"-vs[0-9][0-9]-"$arch".zip)
    zip="${matches[0]}"
    [ -f "$zip" ] ||
        fail "No Windows asset has the name that PIE expects: $name."
    dll="$(basename "$zip" .zip).dll"
    listing="$(unzip -Z1 "$zip")" || fail "Could not list the files in $zip."
    grep -qxF "$dll" <<<"$listing" ||
        fail "$zip does not contain $dll, which PIE loads."
done <<<"$legs"
