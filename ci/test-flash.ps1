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
# Imager 2.x checks --sha256 against the uncompressed image, not the .img.xz
# checksum the script verifies, so passing that hash fails every write.
Assert-True ($flashBody -notmatch "'--sha256'") "Invoke-Flash does not pass the .img.xz checksum as Imager's --sha256"

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
    Assert-True ($s['FLASH_GITHUB_KEY'] -eq 'yes') 'Request-FlashSettings creates a GitHub key without asking'

    $s = @{ FLASH_HOSTNAME = 'given'; FLASH_WIFI_SSID = ''; FLASH_WIFI_PASSWORD = ''; FLASH_WIFI_COUNTRY = ''; FLASH_SSH_PUBKEY_FILE = ''; FLASH_GITHUB_KEY = 'no' }
    $script:answers = @('My WiFi', 'at', 'none')   # no hostname question: it was given
    Request-FlashSettings $s
    Assert-True ($s['FLASH_HOSTNAME'] -eq 'given') 'Request-FlashSettings does not ask for a value that was given'
    Assert-True ($s['FLASH_WIFI_SSID'] -eq 'My WiFi' -and $s['FLASH_WIFI_COUNTRY'] -eq 'at') 'Request-FlashSettings asks for the country after a Wi-Fi name'
    Assert-True (-not $s['FLASH_SSH_PUBKEY_FILE']) "Request-FlashSettings: 'none' means password login only"
    Assert-True ($s['FLASH_GITHUB_KEY'] -eq 'no') 'Request-FlashSettings keeps -GitHubKey no'
} finally {
    Remove-Item function:Read-Answer, function:Test-CanPrompt, function:Get-DefaultPublicKey -ErrorAction SilentlyContinue
}

# --- GitHub key: created in a temp folder, copied to the card, kept out of user-data
$boot = Join-Path ([IO.Path]::GetTempPath()) ("flash_boot_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $boot | Out-Null
$gh = $null
try {
    Set-Content -LiteralPath (Join-Path $boot 'meta-data') -Value ''      # a cloud-init (Trixie) card
    $gh = New-GitHubKey -Comment 'pi@homepi'
    Assert-True ($gh.Public -match '^ssh-ed25519 AAAA\S+ pi@homepi$') 'New-GitHubKey creates an ed25519 key with the user@host comment'
    $privText = [IO.File]::ReadAllText($gh.Private)
    Assert-True ($privText -match 'BEGIN OPENSSH PRIVATE KEY') 'New-GitHubKey writes an unencrypted OpenSSH private key'
    $s = @{ FLASH_HOSTNAME = 'homepi'; FLASH_WIFI_SSID = ''; FLASH_WIFI_PASSWORD = ''; FLASH_WIFI_COUNTRY = ''; FLASH_SSH_PUBKEY_FILE = ''; FLASH_GITHUB_KEY = 'yes' }
    Assert-FlashSettings $s
    $s['GITHUB_KEY'] = $gh
    Write-FirstBootSettings -Root $boot -UserName 'pi' -Settings $s
    $cardKey = [IO.File]::ReadAllText((Join-Path $boot 'rpi-setup-github-key'))
    Assert-True ($cardKey -eq ($privText -replace "`r", '')) 'the private key is copied to the boot partition with LF line endings'
    Assert-True ([IO.File]::ReadAllText((Join-Path $boot 'rpi-setup-github-key.pub')) -eq "$($gh.Public)`n") 'the public key is copied next to it'
    $ud = [IO.File]::ReadAllText((Join-Path $boot 'user-data'))
    Assert-True ($ud -notmatch 'PRIVATE KEY') 'user-data does not contain the private key'
    Assert-True ($ud -match "(?m)^  - path: /usr/local/sbin/rpi-setup-github-key$" -and $ud -match "(?m)^      U='pi'$") 'user-data installs the key-moving script for the login user'
    Assert-True ($ud -match 'install -m 0600 -o "\$U"') 'the key-moving script sets mode 600 and the user as owner'
    Assert-True ($ud -match '(?m)^  - \[systemctl, enable, rpi-setup-github-key\.service\]$') 'user-data enables the one-shot service'
    Assert-True ($ud -notmatch "`r") 'user-data has LF line endings'

    Remove-Item -LiteralPath (Join-Path $boot 'meta-data'), (Join-Path $boot 'user-data')
    Set-Content -LiteralPath (Join-Path $boot 'cmdline.txt') -Value 'console=tty1 root=PARTUUID=x rootwait'
    Write-FirstBootSettings -Root $boot -UserName 'pi' -Settings $s
    $fr = [IO.File]::ReadAllText((Join-Path $boot 'firstrun.sh'))
    Assert-True ($fr -match "(?m)^systemctl enable rpi-setup-github-key\.service$" -and $fr -notmatch 'PRIVATE KEY') 'firstrun.sh (Bookworm) installs and enables the service, without the private key'
} finally {
    if ($gh) { Remove-Item -LiteralPath $gh.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $boot -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-True ($source -match "Remove-Item -LiteralPath \`$firstBoot\['GITHUB_KEY'\]\.Dir") 'main() deletes the temp key folder in its finally block'

# --- Eject: the helper compiles, and main() ejects unless -NoEject
Add-Type -TypeDefinition $Script:EjectSource
Assert-True ([bool]('RpiSetupEject' -as [type])) 'the eject helper compiles'
Assert-True ($source -match '-not \$NoEject -and \(Dismount-Card \$targetDisk\.Number\)') 'main() ejects the card at the end unless -NoEject'

# --- Get-Credentials: the username check is case-sensitive, like flash.sh's
# (Fail exits the process, so the check is asserted on the source).
Assert-True ($source -match "\`$UserName -cnotmatch '\^\[a-z_\]") "Get-Credentials refuses upper-case user names (-cnotmatch)"
Assert-True (-not ('piUser' -cmatch '^[a-z_][a-z0-9_-]{0,31}$') -and ('piuser' -cmatch '^[a-z_][a-z0-9_-]{0,31}$')) 'the user name pattern takes piuser and refuses piUser'

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
