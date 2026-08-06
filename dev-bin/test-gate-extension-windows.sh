#!/usr/bin/env bash
#
# Assert that gate-extension.ps1 accepts a good DLL and rejects bad ones.
#
# Named for the gate it tests rather than as plain test-gate-extension.sh: the
# bash gate lives in the submodule and has its own test of that name, and this
# directory holds no gate-extension.sh at all, so the unqualified name would
# point at a file that is not here.
#
# Both tests exist for the reason the submodule's states: every other caller
# runs its gate over an object it expects to pass, so the gate is only ever
# observed succeeding, and nothing would notice it breaking into certifying
# anything -- or, just as quietly, into refusing everything, which a suite of
# rejection cases alone cannot tell apart from working correctly. Hence a
# positive control first.
#
# It runs on Linux, where pwsh is preinstalled on GitHub's runners and where
# most of the gate is reachable:
#
#   - `Get-Command dumpbin.exe -CommandType Application` finds any executable
#     of that name on PATH, so a shim makes the export checks testable.
#   - the load check runs whatever php-bin\php.exe it found under the build
#     root, so a second shim decides whether the DLL "loads".
#
# Only real dumpbin output against a real DLL is genuinely Windows-only, and
# the Windows lane covers that on every run.
#
# Usage: test-gate-extension-windows.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dev-bin/lib.sh
. "$here/lib.sh"

gate="$here/gate-extension.ps1"
[ -f "$gate" ] || fail "$gate is missing."

# Required, not skipped. A test suite that quietly does nothing when its
# interpreter is absent is the same failure this gate exists to prevent, one
# level up.
command -v pwsh >/dev/null || fail "pwsh is required to test gate-extension.ps1."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Fixtures. The DLLs are empty files: nothing below reads their contents, since
# dumpbin is a shim and php is a shim.
: > "$work/verify.php"
: > "$work/db.mmdb"
mkdir -p "$work/empty"
mkdir -p "$work/good/php-bin" && : > "$work/good/php_maxminddb.dll"
mkdir -p "$work/nophp" && : > "$work/nophp/php_maxminddb.dll"
mkdir -p "$work/twodlls/a" "$work/twodlls/b"
: > "$work/twodlls/a/php_maxminddb.dll"
: > "$work/twodlls/b/php_maxminddb.dll"
mkdir -p "$work/twophp/php-bin" "$work/twophp/nested/php-bin"
: > "$work/twophp/php_maxminddb.dll"

shims="$work/shims"
mkdir -p "$shims"

# The header dumpbin prints before the export table. Reproduced so the parser
# is exercised against the noise it has to skip -- "0.00 version", "1 ordinal
# base" and the Summary section all sit in the same column shape.
dumpbin_header='Microsoft (R) COFF/PE Dumper Version 14.38.33130.0
Copyright (C) Microsoft Corporation.  All rights reserved.

Dump of file php_maxminddb.dll

File Type: DLL

  Section contains the following exports for php_maxminddb.dll

    00000000 characteristics
    FFFFFFFF time date stamp
        0.00 version
           1 ordinal base
           1 number of functions
           1 number of names

    ordinal hint RVA      name
'
dumpbin_footer='
  Summary

        1000 .data
        1000 .rdata'

set_dumpbin() { # <exit status> <table rows>
    {
        echo '#!/usr/bin/env bash'
        echo "cat <<'DUMPBIN_EOF'"
        printf '%s%s%s\n' "$dumpbin_header" "$2" "$dumpbin_footer"
        echo 'DUMPBIN_EOF'
        echo "exit $1"
    } > "$shims/dumpbin.exe"
    chmod +x "$shims/dumpbin.exe"
}

set_php() { # <exit status>
    printf '#!/usr/bin/env bash\necho "php shim: $*"\nexit %s\n' "$1" > "$work/php.exe"
    chmod +x "$work/php.exe"
    cp "$work/php.exe" "$work/good/php-bin/php.exe"
    cp "$work/php.exe" "$work/twophp/php-bin/php.exe"
    cp "$work/php.exe" "$work/twophp/nested/php-bin/php.exe"
}

passed=0
failed=0

# Indents a captured run so a failure's output cannot be mistaken for the
# suite's own.
indent() {
    while IFS= read -r line; do
        printf '        | %s\n' "$line"
    done <<<"$1"
}

check() { # <description> <expected exit: 0|nonzero> <expected substring> <build root> [extra args...]
    local desc="$1" want_exit="$2" want="$3" root="$4"
    shift 4
    local out status ok=1
    set +e
    out="$(PATH="$shims:$PATH" pwsh -NoProfile -File "$gate" \
        "$root" "$work/verify.php" "$work/db.mmdb" 1.13.3 "$@" 2>&1)"
    status=$?
    set -e

    if [ "$want_exit" = 0 ]; then
        [ "$status" -eq 0 ] || ok=0
        # A pass must not carry an error annotation, and a rejection must not
        # be mistaken for one: ::error:: is what the workflow surfaces.
        ! grep -q '::error::' <<<"$out" || ok=0
    else
        [ "$status" -ne 0 ] || ok=0
    fi
    # Matched on the message rather than the status alone, because 126 and 127
    # are non-zero too and "the gate never ran" must not read as "the gate said
    # no".
    grep -qF "$want" <<<"$out" || ok=0

    if [ "$ok" = 1 ]; then
        passed=$((passed + 1))
        printf '  ok    %s\n' "$desc"
    else
        failed=$((failed + 1))
        printf '  FAIL  %s\n        exit %s, wanted %s, looking for %s\n' \
            "$desc" "$status" "$want_exit" "$want"
        indent "$out"
    fi
}

echo "Parsing $gate"
pwsh -NoProfile -Command "
    \$errors = \$null
    [System.Management.Automation.Language.Parser]::ParseFile('$gate', [ref]\$null, [ref]\$errors) > \$null
    if (\$errors.Count) { \$errors | ForEach-Object { \$_.Message }; exit 1 }" ||
    fail "$gate does not parse."

echo
echo "The positive control: without it, a gate broken into always failing"
echo "satisfies every rejection below."
set_php 0
set_dumpbin 0 '          1    0 00001D50 get_module'
check "a good DLL is accepted" 0 "Exports: get_module" "$work/good"
# x86 prints the undecorated export name beside the decorated internal one. The
# exported name is the first column, which is what PHP looks up.
set_dumpbin 0 '          1    0 00001A60 get_module = _get_module'
check "an x86 aliased export table is accepted" 0 "Exports: get_module" "$work/good"

echo
echo "Rejections that need a readable DLL"
set_dumpbin 0 '          1    0 00001D50 MMDB_open'
check "an export table without get_module" 1 "exports no get_module" "$work/good"
set_dumpbin 0 ''
check "an unmeasurable export table is not a rejection" 1 "Read no export table" "$work/good"
set_dumpbin 1 '          1    0 00001D50 get_module'
check "dumpbin failing is reported as dumpbin failing" 1 "dumpbin could not read" "$work/good"
set_dumpbin 0 '          1    0 00001D50 get_module'
set_php 1
check "a DLL php cannot load" 1 "did not load and query cleanly" "$work/good"
set_php 0

echo
echo "-BuildFailed downgrades absent artefacts to a note"
check "no build root" 0 "::notice::" "$work/nope" -BuildFailed
check "no DLL" 0 "::notice::" "$work/empty" -BuildFailed

echo
echo "...and the same absences stay errors when the build succeeded"
check "no build root" 1 "does not exist" "$work/nope"
check "no DLL" 1 "Expected exactly one php_maxminddb.dll" "$work/empty"

echo
echo "The leniency stops at the DLL. These must fail even with -BuildFailed,"
echo "and this is the asymmetry a refactor would quietly flatten."
check "two DLLs" 1 "Expected exactly one php_maxminddb.dll" "$work/twodlls" -BuildFailed
check "a DLL but no php-bin" 1 "Expected exactly one php-bin" "$work/nophp" -BuildFailed
check "two php-bin copies" 1 "Expected exactly one php-bin" "$work/twophp" -BuildFailed

echo
echo "A broken call is this workflow's fault, not the build's"
# Called directly rather than through check(), which supplies a verifier that
# exists. -BuildFailed too: the leniency must not extend to the caller's own
# arguments, which come from the checkout and not from the build.
set +e
out="$(PATH="$shims:$PATH" pwsh -NoProfile -File "$gate" \
    "$work/good" "$work/absent.php" "$work/db.mmdb" 1.13.3 -BuildFailed 2>&1)"
status=$?
set -e
if [ "$status" -ne 0 ] && grep -qF "absent.php does not exist" <<<"$out"; then
    passed=$((passed + 1))
    echo "  ok    a missing verifier, even with -BuildFailed"
else
    failed=$((failed + 1))
    echo "  FAIL  a missing verifier was accepted"
    indent "$out"
fi

set +e
out="$(PATH="$shims:$PATH" pwsh -NoProfile -File "$gate" "$work/good" 2>&1)"
status=$?
set -e
if [ "$status" -ne 0 ]; then
    passed=$((passed + 1))
    echo "  ok    too few arguments"
else
    failed=$((failed + 1))
    echo "  FAIL  the gate accepted a call with too few arguments"
fi

echo
echo "$passed passed, $failed failed."
[ "$failed" -eq 0 ] || fail "gate-extension.ps1 did not behave as expected."
