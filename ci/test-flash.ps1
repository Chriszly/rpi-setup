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
# Imager's --cli parser exits on unknown options (--disable-telemetry is GUI-only),
# and without --disable-eject the card is ejected before the first-boot files go on.
Assert-True ($flashBody -notmatch "'--disable-telemetry'") "Invoke-Flash does not pass the GUI-only --disable-telemetry to Imager's --cli mode"
Assert-True ($flashBody -match "'--disable-eject'") "Invoke-Flash passes --disable-eject so the boot partition stays mounted"

# --- Request-FlashSettings: asks only for what was not given, Enter keeps defaults
function Test-CanPrompt { $true }
$script:answers = @()
function Read-Answer { param([string]$Prompt) $a = $script:answers[0]; $script:answers = @($script:answers | Select-Object -Skip 1); $a }
$defaultKey = 'C:\keys\id_ed25519.pub'
function Get-DefaultPublicKey { $defaultKey }
try {
    $s = @{ FLASH_HOSTNAME = ''; FLASH_WIFI_SSID = ''; FLASH_WIFI_PASSWORD = ''; FLASH_WIFI_COUNTRY = ''; FLASH_SSH_PUBKEY_FILE = '' }
    $script:answers = @('homepi', '', '')          # hostname, no Wi-Fi, default key
    Request-FlashSettings $s
    Assert-True ($s['FLASH_HOSTNAME'] -eq 'homepi') 'Request-FlashSettings takes the typed hostname'
    Assert-True (-not $s['FLASH_WIFI_SSID'] -and -not $s['FLASH_WIFI_COUNTRY']) 'Request-FlashSettings: empty Wi-Fi name means cable only, no country asked'
    Assert-True ($s['FLASH_SSH_PUBKEY_FILE'] -eq $defaultKey) 'Request-FlashSettings: Enter takes the key found in ~\.ssh'

    $s = @{ FLASH_HOSTNAME = 'given'; FLASH_WIFI_SSID = ''; FLASH_WIFI_PASSWORD = ''; FLASH_WIFI_COUNTRY = ''; FLASH_SSH_PUBKEY_FILE = '' }
    $script:answers = @('My WiFi', 'at', 'none')   # no hostname question: it was given
    Request-FlashSettings $s
    Assert-True ($s['FLASH_HOSTNAME'] -eq 'given') 'Request-FlashSettings does not ask for a value that was given'
    Assert-True ($s['FLASH_WIFI_SSID'] -eq 'My WiFi' -and $s['FLASH_WIFI_COUNTRY'] -eq 'at') 'Request-FlashSettings asks for the country after a Wi-Fi name'
    Assert-True (-not $s['FLASH_SSH_PUBKEY_FILE']) "Request-FlashSettings: 'none' means password login only"
} finally {
    Remove-Item function:Read-Answer, function:Test-CanPrompt, function:Get-DefaultPublicKey -ErrorAction SilentlyContinue
}

# --- main() asks for the disk before the slow part (Imager, download, write)
Assert-True ($source -match '(?s)\$targetDisk\s*=\s*Select-Disk\s*\$Disk.*\$imager\s*=\s*Find-Imager') 'main() selects the disk before Imager and the download'

# --- main() must not assign the selected disk to $disk (collides with [int]$Disk)
Assert-True ($source -match '\$targetDisk\s*=\s*Select-Disk\s*\$Disk') "main() assigns Select-Disk result to `$targetDisk (avoids [int]`$Disk collision)"

if ($script:failures -gt 0) {
    Write-Host ''
    Write-Host "[FAIL] $script:failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host '[PASS] All flash.ps1 unit tests passed.' -ForegroundColor Green
