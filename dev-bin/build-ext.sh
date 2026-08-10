#!/usr/bin/env bash
#
# Build maxminddb.so from the submodule's ext/ sources and record the fields the
# published asset name is derived from. Used by both Unix lanes: on Linux inside
# a digest-pinned container, on macOS directly on the runner. Windows builds
# through php/php-windows-builder and does not run this.
#
# Usage: build-ext.sh <ext-dir> <out-dir>

set -euo pipefail

ext_dir="$1"
out_dir="$2"

# --with-maxminddb-bundled compiles libmaxminddb's vendored sources into the
# extension so the published .so needs nothing but libc. config.m4 does refuse
# this itself -- AC_MSG_ERROR on both a missing --with-maxminddb and missing
# sources -- so this is not the only thing standing between us and a binary with
# a dangling libmaxminddb dependency. It is worth keeping because it fires
# before phpize and says so as a GitHub annotation rather than in autoconf
# output partway down a job log.
if [ ! -f "$ext_dir/libmaxminddb/src/maxminddb.c" ]; then
    echo "::error::$ext_dir/libmaxminddb is missing. The submodule must point at a commit that supports --with-maxminddb-bundled."
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
