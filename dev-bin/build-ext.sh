#!/usr/bin/env bash
#
# Build maxminddb.so from the submodule's ext/ sources and record the fields the
# published asset name is derived from. Used by both release lanes: on Linux
# inside a digest-pinned container, on macOS directly on the runner.
#
# Usage: build-ext.sh <ext-dir> <out-dir>

set -euo pipefail

ext_dir="$1"
out_dir="$2"

# --with-maxminddb-bundled compiles libmaxminddb's vendored sources into the
# extension so the published .so needs nothing but libc. Without those sources
# ./configure silently falls back to looking for a system library and we would
# ship a binary with a dangling libmaxminddb dependency, so stop here instead.
if [ ! -f "$ext_dir/libmaxminddb/src/maxminddb.c" ]; then
    echo "::error::$ext_dir/libmaxminddb is missing. The submodule must point at a tag that supports --with-maxminddb-bundled."
    exit 1
fi

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)" # absolute, because the build cd's away
cd "$ext_dir"
phpize
./configure --with-maxminddb --with-maxminddb-bundled
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
cp modules/maxminddb.so "$out_dir/maxminddb.so"

# Record these as reported by the PHP that actually built the object, so the
# asset filename cannot disagree with the binary inside it.
php-config --version | cut -d. -f1,2 > "$out_dir/php-abi"
php -r 'echo ZEND_THREAD_SAFE ? "-zts" : "";' > "$out_dir/ts-suffix"
