#!/usr/bin/env pwsh
#
# The Windows half of MaxMind-DB-Reader-php/dev-bin/gate-extension.sh -- in the
# submodule, not beside this file, which has no .sh counterpart: refuse to
# publish a
# php_maxminddb.dll that PHP will not load. Written in PowerShell rather than
# added to the bash gate because nothing it uses -- dumpbin, the PHP the build
# downloaded -- exists on the Unix lanes, and nothing the bash gate uses exists
# here.
#
# Usage: gate-extension.ps1 <build root> <verifier> <database> <version> [-BuildFailed]
#
# <build root> is the directory php/php-windows-builder was told to build in. It
# builds under a per-run subdirectory of that, which is where both the DLL and
# the php-bin it was built against are found.
#
# -BuildFailed says the build step has already failed, which the caller knows
# and this script cannot tell: a build that dies before linking leaves the same
# empty tree as one that never ran. It downgrades exactly two things to a note
# -- an absent build root and an absent DLL -- because the build has already
# reported the real cause and a second ::error:: would only compete with it.
#
# It deliberately stops there. A DLL that is present but wrong is still
# rejected, which is the whole reason to run on a failed build: the failure is
# often a symptom of the defect rather than a reason not to look for it.
#
# The bash gate runs five checks and this runs two. The asymmetry is deliberate,
# so all five are accounted for here rather than left to be reconstructed:
#
#   - get_module is exported                 -- checked below, and the whole
#                                               reason this file exists.
#   - loads and queries a real database      -- checked below.
#   - no undefined symbols                   -- not applicable. A DLL cannot
#                                               link with unresolved imports,
#                                               so there is nothing to measure.
#   - no libmaxminddb in the imports         -- not applicable. The
#                                               libmaxminddb PHP publishes for
#                                               Windows is a static .lib with no
#                                               DLL beside it, so the import is
#                                               absent whether we built the
#                                               bundled sources or linked the
#                                               fetched library. An assertion
#                                               that always holds would say
#                                               nothing about which we built.
#   - nothing but get_module is exported     -- not checked. MSVC exports only
#                                               what is marked dllexport, so
#                                               this holds by construction --
#                                               though the export table read
#                                               below would make asserting it
#                                               nearly free.

param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = 'Directory the extension was built in')]
    [string] $BuildRoot,
    [Parameter(Mandatory = $true, Position = 1, HelpMessage = 'Path to verify-extension.php')]
    [string] $Verifier,
    [Parameter(Mandatory = $true, Position = 2, HelpMessage = 'Path to a test database')]
    [string] $Database,
    [Parameter(Mandatory = $true, Position = 3, HelpMessage = 'Expected MMDB_LIB_VERSION')]
    [string] $ExpectedVersion,
    [Parameter(HelpMessage = 'The build step already failed; do not report missing artefacts as errors')]
    [switch] $BuildFailed
)

$ErrorActionPreference = 'Stop'
# Every exit code below is checked and reported by hand, so keep PowerShell from
# turning one into a bare NativeCommandExitException before it gets there. The
# default differs between PowerShell versions; this does not.
$PSNativeCommandUseErrorActionPreference = $false

function Fail([string] $Message) {
    Write-Host "::error::$Message"
    throw $Message
}

function Skip([string] $Message) {
    # ::notice:: rather than Write-Host: this is the only branch in the gate
    # that votes to pass, and the step reports success afterwards. A plain log
    # line makes "the gate did not run" indistinguishable from "the gate ran".
    Write-Host "::notice::The build failed $Message, so the gate had nothing to check."
    exit 0
}

function Find-Only([string] $What, $Candidates) {
    $found = @($Candidates | Where-Object { $null -ne $_ })
    if ($found.Count -ne 1) {
        Fail "Expected exactly one $What under $BuildRoot, found $($found.Count)."
    }
    return $found[0].FullName
}

# $Verifier and $Database come from the checkout that precedes the build, so
# they are missing only if something is wrong with this workflow rather than
# with the build, and that is worth an error even on a failed run.
if (-not (Test-Path -LiteralPath $BuildRoot)) {
    if ($BuildFailed) {
        Skip "before creating $BuildRoot"
    }
    Fail "$BuildRoot does not exist."
}
foreach ($path in @($Verifier, $Database)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "$path does not exist."
    }
}

# -ErrorAction SilentlyContinue on the walks below because the build tree holds
# unpacked PHP and SDK archives whose paths can be too long to enumerate. A path
# that could not be walked shows up as a file that was not found, which fails.
$dlls = @(
    Get-ChildItem -LiteralPath $BuildRoot -Recurse -File -Filter 'php_maxminddb.dll' `
        -ErrorAction SilentlyContinue
)
# The last absence a failed build accounts for, and the narrowest useful place
# to stop: everything below is required of it even then. Once a DLL exists the
# build reached the linker, php-bin was downloaded long before that, and a
# missing one is its own anomaly rather than a consequence of the failure.
if ($dlls.Count -eq 0 -and $BuildFailed) {
    Skip 'before producing a DLL'
}
$dll = Find-Only 'php_maxminddb.dll' $dlls
# The PHP the extension was built against, and the only one whose version,
# thread safety and architecture are guaranteed to match it.
$php = Find-Only 'php-bin\php.exe' (
    Get-ChildItem -LiteralPath $BuildRoot -Recurse -File -Filter 'php.exe' `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'php-bin' }
)

Write-Host "Gating $dll with $php"

# 1. The DLL must export get_module. This is the direct form of the failure the
#    gate exists for: an object path collision under phpize overwrote the
#    extension's own object with libmaxminddb's, configure, nmake and the
#    packaging step all accepted the result, and PHP then rejected it at startup
#    as "Invalid library (maybe not a PHP library)".
#
#    dumpbin ships with MSVC but is not on PATH outside a developer prompt, and
#    this step is not one. vswhere is installed with every Visual Studio and is
#    the supported way to ask where it went; prefer the x64-hosted copy, which
#    reads DLLs of either architecture.
$dumpbin = $null
$command = Get-Command dumpbin.exe -CommandType Application -ErrorAction SilentlyContinue
if ($null -ne $command) {
    $dumpbin = $command.Source
} elseif ($null -ne ${env:ProgramFiles(x86)}) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        # Both invocations report their exit status. Neither is fatal on its
        # own -- the first has a documented fallback and the second ends at the
        # same Fail below -- but a vswhere that failed and a vswhere that found
        # nothing are different facts, and without this they arrive as the same
        # message.
        $vswhereTrouble = @()
        $candidates = @(& $vswhere -latest -prerelease -products * -find '**\dumpbin.exe')
        if ($LASTEXITCODE -ne 0) {
            # -find needs vswhere 2.6; an older one errors rather than returning
            # nothing, which is what this fallback is for.
            $vswhereTrouble += "-find exited $LASTEXITCODE"
            $candidates = @()
        }
        if ($candidates.Count -eq 0) {
            # The documented toolset path under whichever Visual Studio vswhere
            # reports.
            $installed = & $vswhere -latest -prerelease -products * -property installationPath
            if ($LASTEXITCODE -ne 0) {
                $vswhereTrouble += "-property installationPath exited $LASTEXITCODE"
                $installed = $null
            }
            if ($installed) {
                $glob = Join-Path $installed 'VC\Tools\MSVC\*\bin\Host*\*\dumpbin.exe'
                $candidates = @(Resolve-Path -Path $glob -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Path })
            }
        }
        $dumpbin = $candidates | Where-Object { $_ -match 'Hostx64\\x64' } | Select-Object -First 1
        if ($null -eq $dumpbin) {
            $dumpbin = $candidates | Select-Object -First 1
        }
    }
}
if ($null -eq $dumpbin) {
    $why = if ($vswhereTrouble.Count -gt 0) { " (vswhere: $($vswhereTrouble -join '; '))" } else { '' }
    Fail "Found no dumpbin.exe, so the export table cannot be read.$why"
}

Write-Host "Reading exports with $dumpbin"
$exports = & $dumpbin /nologo /exports $dll
if ($LASTEXITCODE -ne 0) {
    Fail "dumpbin could not read $dll (exit $LASTEXITCODE)."
}
# Parsed out of the ordinal/hint/RVA/name table rather than matched against all
# of dumpbin's output. Grepping cannot tell an unreadable or empty export table
# from a table that simply lacks the symbol, so an unmeasurable result would be
# reported as a rejection -- the shared bash gate's header states the opposite
# principle, that an unmeasurable result is fatal as such.
#
# It also removes a dependency on output the x86 legs only pass by accident:
# there dumpbin prints "get_module = _get_module", and '\bget_module\b' matches
# the undecorated half. Against a bare _get_module it would not match at all,
# because _ is a word character and there is no boundary before it.
$exportNames = @(
    foreach ($line in $exports) {
        if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)') { $Matches[1] }
    }
)
if ($exportNames.Count -eq 0) {
    Fail "Read no export table from $dll, so whether it exports get_module is unverified."
}
Write-Host "Exports: $($exportNames -join ', ')"
if ($exportNames -notcontains 'get_module') {
    Fail "$dll exports no get_module, so PHP would reject it as not a PHP library."
}

# 2. Load it and query a real database, the equivalent of the Linux lane's
#    clean-container run. `-n` so no php.ini can supply anything the DLL needs,
#    and verify-extension.php exits non-zero when the extension is not loaded:
#    PHP only warns about a library it could not use and would otherwise leave
#    the exit code at 0, which is the quietness this gate is here to end.
Write-Host 'Loading the extension and querying a database'
& $php -n -d "extension=$dll" $Verifier $Database $ExpectedVersion
if ($LASTEXITCODE -ne 0) {
    Fail "$dll did not load and query cleanly (exit $LASTEXITCODE)."
}
