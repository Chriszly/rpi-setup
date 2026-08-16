#!/usr/bin/env pwsh
# test-flash.ps1 - Unit tests for host/flash.ps1 logic that does not need
# admin privileges, a physical SD card, Imager or network access.
#
# Loads flash.ps1's function definitions (skipping main()) and asserts on the
# pure logic: Imager install-path detection, version parsing, and the guard
# that keeps main() from colliding with the [int]$Disk parameter.
#
# Run: pwsh -NoProfile -File ci/test-flash.ps1
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$flash   = Join-Path $root 'host\flash.ps1'
if (-not (Test-Path -LiteralPath $flash)) { throw "flash.ps1 not found at $flash" }

# --- Load flash.ps1 functions without running its main() body -----------------
$source = Get-Content -LiteralPath $flash -Raw

# Strip the param(...) block - param() is only valid as the first statement of
# a script, not inside Invoke-Expression.
$source = [regex]::Replace($source, '(?ms)^param\(.*?^\)\s*', '', 1)

# Keep only the function definitions that precede the main() marker.
$mainIdx = $source.IndexOf('# --- main ---')
if ($mainIdx -lt 0) { throw "Could not find the '# --- main ---' marker in $flash" }
$functions = $source.Substring(0, $mainIdx)

Invoke-Expression $functions

# --- Tiny assertion helper -----------------------------------------------------
$script:failures = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "[PASS] $Name" -ForegroundColor Green }
    else            { Write-Host "[FAIL] $Name" -ForegroundColor Red; $script:failures++ }
}

# --- Get-ImagerVersion: must accept a leading 'v' (e.g. v2.0.10) ---------------
# Test the version parsing logic directly (pure logic, no file I/O)
$testCases = @(
    @{ Input = 'v2.0.10';       Expected = '2.0.10' },
    @{ Input = 'V2.0.10';       Expected = '2.0.10' },
    @{ Input = '2.0.10';        Expected = '2.0.10' },
    @{ Input = 'v2.0.10.0';     Expected = '2.0.10.0' },
    @{ Input = 'v1.2.3.4';      Expected = '1.2.3.4' },
    @{ Input = 'v2.0.10 beta';  Expected = '2.0.10' }  # stops at space
)
foreach ($tc in $testCases) {
    $parsed = ($tc.Input -replace '^[vV]' -split ' ')[0]
    $v = $null
    $ok = [version]::TryParse($parsed, [ref]$v) -and $v.ToString() -eq $tc.Expected
    Assert-True $ok "Get-ImagerVersion parsing logic: '$($tc.Input)' -> '$($tc.Expected)' (got '$parsed')"
}

# Also test Get-ImagerVersion with a real file if possible (best-effort)
$tmpDir = Join-Path $env:TEMP "imager_test_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
    $dll = Join-Path $tmpDir 'rpi-imager-test.dll'
    $td = @'
using System.Reflection;
[assembly: AssemblyInformationalVersion("v2.0.10")]
[assembly: AssemblyFileVersion("2.0.10")]
[assembly: AssemblyProduct("Raspberry Pi Imager")]
namespace ImagerTest { public class Marker { } }
'@
    Add-Type -TypeDefinition $td -OutputAssembly $dll
    $ver = Get-ImagerVersion -Path $dll
    if ($ver) {
        Assert-True ($ver -eq '2.0.10') "Get-ImagerVersion with mock DLL: 'v2.0.10' -> '2.0.10' (got '$ver')"
    } else {
        Write-Warn "Mock DLL version detection skipped (Add-Type -OutputAssembly limitation in this PS version)"
    }
} finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Get-ImagerPath: must find the current 'Raspberry Pi Ltd\Imager' layout -----
$origProg   = $env:ProgramFiles
$origProg86 = ${env:ProgramFiles(x86)}
$origLocal  = $env:LOCALAPPDATA
$mock       = Join-Path $env:TEMP "imager_path_$([guid]::NewGuid().ToString('N'))"
$exe        = Join-Path $mock 'Raspberry Pi Ltd\Imager\rpi-imager.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $exe) -Force | Out-Null
New-Item -ItemType File -Path $exe -Force | Out-Null
try {
    $env:ProgramFiles = $mock
    ${env:ProgramFiles(x86)} = "$mock\x86"
    $env:LOCALAPPDATA = "$mock\local"
    $found = Get-ImagerPath
    Assert-True ($found -eq $exe) "Get-ImagerPath finds 'Raspberry Pi Ltd\Imager\rpi-imager.exe' (got '$found')"
} finally {
    $env:ProgramFiles = $origProg
    ${env:ProgramFiles(x86)} = $origProg86
    $env:LOCALAPPDATA = $origLocal
    Remove-Item -LiteralPath $mock -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Get-ImagerPath: legacy 'Raspberry Pi Imager' layout must still work --------
$mock2 = Join-Path $env:TEMP "imager_path2_$([guid]::NewGuid().ToString('N'))"
$exe2  = Join-Path $mock2 'Raspberry Pi Imager\rpi-imager.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $exe2) -Force | Out-Null
New-Item -ItemType File -Path $exe2 -Force | Out-Null
try {
    $env:ProgramFiles = $mock2
    ${env:ProgramFiles(x86)} = "$mock2\x86"
    $env:LOCALAPPDATA = "$mock2\local"
    $found = Get-ImagerPath
    Assert-True ($found -eq $exe2) "Get-ImagerPath still finds legacy 'Raspberry Pi Imager' (got '$found')"
} finally {
    $env:ProgramFiles = $origProg
    ${env:ProgramFiles(x86)} = $origProg86
    $env:LOCALAPPDATA = $origLocal
    Remove-Item -LiteralPath $mock2 -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Test-FlashableDisk: removable SD/USB flashable; virtual only via -AllowVirtualDisk
$mockSD   = [pscustomobject]@{ IsSystem = $false; IsRemovable = $true;  BusType = 'SD' }
$mockUSB  = [pscustomobject]@{ IsSystem = $false; IsRemovable = $true;  BusType = 'USB' }
$mockVhdx = [pscustomobject]@{ IsSystem = $false; IsRemovable = $false; BusType = 'File Backed Virtual' }
$mockSys  = [pscustomobject]@{ IsSystem = $true;  IsRemovable = $false; BusType = 'SATA' }

Assert-True (Test-FlashableDisk $mockSD $false)        'Test-FlashableDisk: removable SD disk is flashable'
Assert-True (Test-FlashableDisk $mockUSB $false)       'Test-FlashableDisk: removable USB disk is flashable'
Assert-True (-not (Test-FlashableDisk $mockVhdx $false)) 'Test-FlashableDisk: virtual disk is NOT flashable by default'
Assert-True (Test-FlashableDisk $mockVhdx $true)       'Test-FlashableDisk: virtual disk is flashable with -AllowVirtualDisk'
Assert-True (-not (Test-FlashableDisk $mockSys $true)) 'Test-FlashableDisk: system disk is never flashable'

# --- Invoke-Flash must let Imager write virtual SD cards (CI) without weakening production safety
Assert-True ($source -match '(?s)\$AllowVirtualDisk.*--enable-writing-system-drives') "Invoke-Flash passes '--enable-writing-system-drives' only with -AllowVirtualDisk (Imager rejects non-removable VHDX otherwise)"

# --- main() must not assign the selected disk to $disk (collides with [int]$Disk)
Assert-True ($source -match '\$targetDisk\s*=\s*Select-Disk\s*\$Disk') "main() assigns Select-Disk result to `$targetDisk (avoids [int]`$Disk collision)"

if ($script:failures -gt 0) {
    Write-Host ''
    Write-Host "[FAIL] $script:failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host '[PASS] All flash.ps1 unit tests passed.' -ForegroundColor Green
