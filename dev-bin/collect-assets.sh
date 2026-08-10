#!/usr/bin/env bash
#
# Collect one release asset out of each staged artifact directory and assert
# that the set is complete. Run by verify-assets on every run, and again by
# publish immediately before it uploads, so a pull request exercises the same
# assertion a release depends on.
#
# Usage: collect-assets.sh <dist-dir> <assets-dir>
#
# Reads TAG, PHP_VERSIONS, TS_MODES, LINUX_ARCHES and WINDOWS_COUNT.

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

# set -u does not fire on a set-but-empty variable, and arithmetic coerces one
# to 0 -- so an empty WINDOWS_COUNT would quietly mean "expect no Windows
# assets", and a release missing all of them would match the expectation and
# ship. Require a count before using it as one.
case "${WINDOWS_COUNT:-}" in
'' | *[!0-9]*)
    fail "WINDOWS_COUNT is '${WINDOWS_COUNT:-}', which is not a count."
    ;;
esac

php_count="$(jq 'length' <<<"$PHP_VERSIONS")"
ts_count="$(jq 'length' <<<"$TS_MODES")"
arch_count="$(jq 'length' <<<"$LINUX_ARCHES")"
# Linux (php x ts x arch) + macOS (php x ts).
binary_count=$((php_count * ts_count * arch_count + php_count * ts_count))

# 1 source tarball + the binary lanes + whatever the Windows matrix said it
# would produce. Everything but WINDOWS_COUNT comes from setup, which is also
# what each matrix expands, so the expectation cannot drift from what was built
# -- including when setup hands out the reduced pull-request lists. WINDOWS_COUNT
# comes from windows-matrix, which derives it from the matrix it emits.
expected=$((1 + binary_count + WINDOWS_COUNT))

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
