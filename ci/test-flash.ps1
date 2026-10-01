#!/usr/bin/env pwsh
# test-flash.ps1 - Unit tests for host/flash.ps1 logic that does not need
# admin privileges, a physical SD card, Imager or network access.
#
# Loads flash.ps1's function definitions (skipping main()) and asserts on the
# pure logic: Imager install-path detection, argument quoting, and the guard
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

# --- Get-ImagerPath: finds the current and the legacy install layout ------------
$origProg   = $env:ProgramFiles
$origProg86 = ${env:ProgramFiles(x86)}
$origLocal  = $env:LOCALAPPDATA
foreach ($layout in @('Raspberry Pi Ltd\Imager', 'Raspberry Pi Imager')) {
    $mock = Join-Path $env:TEMP "imager_path_$([guid]::NewGuid().ToString('N'))"
    $exe  = Join-Path $mock "$layout\rpi-imager.exe"
    New-Item -ItemType Directory -Path (Split-Path -Parent $exe) -Force | Out-Null
    New-Item -ItemType File -Path $exe -Force | Out-Null
    try {
        $env:ProgramFiles = $mock
        ${env:ProgramFiles(x86)} = "$mock\x86"
        $env:LOCALAPPDATA = "$mock\local"
        $found = Get-ImagerPath
        Assert-True ($found -eq $exe) "Get-ImagerPath finds '$layout\rpi-imager.exe' (got '$found')"
    } finally {
        $env:ProgramFiles = $origProg
        ${env:ProgramFiles(x86)} = $origProg86
        $env:LOCALAPPDATA = $origLocal
        Remove-Item -LiteralPath $mock -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- ConvertTo-ArgumentString: quote only what needs it, escape embedded quotes
Assert-True ((ConvertTo-ArgumentString @('--cli', 'C:\a b\img.xz', '\\.\PhysicalDrive2')) -eq '--cli "C:\a b\img.xz" \\.\PhysicalDrive2') 'ConvertTo-ArgumentString quotes arguments containing spaces'
Assert-True ((ConvertTo-ArgumentString @('say "hi"')) -eq '"say \"hi\""') 'ConvertTo-ArgumentString escapes embedded double quotes'

# --- Invoke-Flash must wait for the GUI-subsystem rpi-imager.exe to finish
$flashBody = [regex]::Match($source, '(?s)function Invoke-Flash \{.*?\n\}').Value
Assert-True ($flashBody -match 'Start-Process[^\n]*-Wait') "Invoke-Flash runs Imager via Start-Process -Wait (rpi-imager.exe is a GUI app; '&' returns immediately)"
Assert-True ($flashBody -notmatch '&\s*\$(Imager|exe)\b') "Invoke-Flash never uses the call operator on the Imager binary"

# --- main() must not assign the selected disk to $disk (collides with [int]$Disk)
Assert-True ($source -match '\$targetDisk\s*=\s*Select-Disk\s*\$Disk') "main() assigns Select-Disk result to `$targetDisk (avoids [int]`$Disk collision)"

if ($script:failures -gt 0) {
    Write-Host ''
    Write-Host "[FAIL] $script:failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host '[PASS] All flash.ps1 unit tests passed.' -ForegroundColor Green
