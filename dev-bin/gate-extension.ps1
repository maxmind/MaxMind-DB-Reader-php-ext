#!/usr/bin/env pwsh
#
# The Windows half of dev-bin/gate-extension.sh: refuse to publish a
# php_maxminddb.dll that PHP will not load. Written in PowerShell rather than
# added to the bash gate because nothing it uses -- dumpbin, the PHP the build
# downloaded -- exists on the Unix lanes, and nothing the bash gate uses exists
# here.
#
# Usage: gate-extension.ps1 <build root> <verifier> <database>
#
# <build root> is the directory php/php-windows-builder was told to build in. It
# builds under a per-run subdirectory of that, which is where both the DLL and
# the php-bin it was built against are found.
#
# There is deliberately no Windows analogue of the .so's libmaxminddb NEEDED
# check. The libmaxminddb that PHP publishes for Windows is a static
# libmaxminddb.lib with no DLL beside it, so the extension carries no
# libmaxminddb import whether it was built from the bundled sources or against
# the fetched library, and an assertion that always holds would tell us nothing
# about which one we built.

param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = 'Directory the extension was built in')]
    [string] $BuildRoot,
    [Parameter(Mandatory = $true, Position = 1, HelpMessage = 'Path to verify-extension.php')]
    [string] $Verifier,
    [Parameter(Mandatory = $true, Position = 2, HelpMessage = 'Path to a test database')]
    [string] $Database,
    [Parameter(Mandatory = $true, Position = 3, HelpMessage = 'Expected MMDB_LIB_VERSION')]
    [string] $ExpectedVersion
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

function Find-Only([string] $What, $Candidates) {
    $found = @($Candidates | Where-Object { $null -ne $_ })
    if ($found.Count -ne 1) {
        Fail "Expected exactly one $What under $BuildRoot, found $($found.Count)."
    }
    return $found[0].FullName
}

foreach ($path in @($BuildRoot, $Verifier, $Database)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "$path does not exist."
    }
}

# -ErrorAction SilentlyContinue on the walks below because the build tree holds
# unpacked PHP and SDK archives whose paths can be too long to enumerate. A path
# that could not be walked shows up as a file that was not found, which fails.
$dll = Find-Only 'php_maxminddb.dll' (
    Get-ChildItem -LiteralPath $BuildRoot -Recurse -File -Filter 'php_maxminddb.dll' `
        -ErrorAction SilentlyContinue
)
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
        $candidates = @(& $vswhere -latest -prerelease -products * -find '**\dumpbin.exe')
        if ($candidates.Count -eq 0) {
            # -find needs vswhere 2.6; fall back to the documented toolset path
            # under whichever Visual Studio vswhere reports.
            $installed = & $vswhere -latest -prerelease -products * -property installationPath
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
    Fail 'Found no dumpbin.exe, so the export table cannot be read.'
}

Write-Host "Reading exports with $dumpbin"
$exports = & $dumpbin /nologo /exports $dll
if ($LASTEXITCODE -ne 0) {
    Fail "dumpbin could not read $dll (exit $LASTEXITCODE)."
}
$export = $exports | Select-String -Pattern '\bget_module\b' | Select-Object -First 1
if ($null -eq $export) {
    Fail "$dll exports no get_module, so PHP would reject it as not a PHP library."
}
Write-Host "get_module export: $($export.Line.Trim())"

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
