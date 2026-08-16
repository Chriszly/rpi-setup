#!/usr/bin/env pwsh
# flash.ps1 - Prepare an SD card for a headless Raspberry Pi (Windows host).
#
#   * downloads the latest Raspberry Pi OS Lite (arm64, 64-bit) image
#   * verifies its SHA-256 checksum
#   * writes it to an SD card with Raspberry Pi Imager
#   * enables SSH and creates a login user (headless first boot)
#
# If Raspberry Pi Imager is missing or outdated, the latest installer is
# downloaded and installed silently (unless -SkipImagerInstall). When the
# script performed the install, Raspberry Pi Imager is uninstalled again once
# flashing completes. Also requires openssl (bundled with Git for Windows)
# unless -SkipCustomize.
# Run in an elevated PowerShell. See README.md for the full workflow.
#
# Examples:
#   .\host\flash.ps1                              # interactive
#   .\host\flash.ps1 -Disk 2 -UserName pi -Password 'changeme'
#   .\host\flash.ps1 -Image C:\dl\raspios.img.xz # use an image you already have
#Requires -Version 5.1

[CmdletBinding()]
param(
    # Physical disk number to overwrite (e.g. 2). Omitting lists candidates.
    [int]$Disk = -1,
    # Local image to flash instead of downloading (accepts .img or .img.xz).
    [string]$Image,
    # Username to create on the Pi (prompted if omitted).
    [string]$UserName,
    # Password for the Pi user (prompted if omitted).
    [string]$Password,
    # Where to cache the downloaded image. Defaults to .\downloads.
    [string]$DownloadDir,
    # Do not download; require a cached image in $DownloadDir.
    [switch]$SkipDownload,
    # Skip SSH/user pre-configuration (boot to the on-screen setup wizard instead).
    [switch]$SkipCustomize,
    # Path to rpi-imager.exe / rpi-imager-cli.cmd (auto-detected if omitted).
    [string]$ImagerExe,
    # Do not auto-install/auto-update Raspberry Pi Imager; fail if it is missing.
    [switch]$SkipImagerInstall
)

$ErrorActionPreference = 'Stop'

$Script:BaseUri        = 'https://downloads.raspberrypi.com/raspios_lite_arm64'
$Script:DefaultRelease = 'raspios_lite_arm64-2026-06-19'                    # fallback if the archive cannot be parsed
$Script:DefaultImage   = '2026-06-18-raspios-trixie-arm64-lite.img.xz'     # fallback file within $Script:DefaultRelease
$Script:ImagerInstalledByScript = $false                                    # set when Install-Imager succeeds

function Write-Step { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail       { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ImagerPath {
    if ($ImagerExe) {
        if (Test-Path -LiteralPath $ImagerExe) { return $ImagerExe }
        return $null
    }
    $candidates = @()
    if (Get-Command rpi-imager-cli -ErrorAction SilentlyContinue) { $candidates += (Get-Command rpi-imager-cli).Source }
    if (Get-Command rpi-imager -ErrorAction SilentlyContinue)     { $candidates += (Get-Command rpi-imager).Source }
    $candidates += @(
        "$env:ProgramFiles(x86)\Raspberry Pi Imager\rpi-imager.exe",
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe",
        "$env:LOCALAPPDATA\Raspberry Pi Imager\rpi-imager.exe",
        "$env:LOCALAPPDATA\Programs\Raspberry Pi Imager\rpi-imager.exe",
        "$env:ProgramFiles(x86)\Raspberry Pi Imager\rpi-imager-cli.cmd",
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager-cli.cmd"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-ImagerLatestVersion {
    # imager_latest.exe 302-redirects to imager_<version>.exe; the final URL encodes the version.
    $target = & curl.exe -sIL -o NUL -w '%{url_effective}' 'https://downloads.raspberrypi.com/imager/imager_latest.exe'
    if ($LASTEXITCODE -ne 0) { return $null }
    $m = [regex]::Match($target, 'imager_(\d+\.\d+\.\d+(?:\.\d+)?)\.exe')
    $v = $null
    if ($m.Success -and [version]::TryParse($m.Groups[1].Value, [ref]$v)) { return $v }
    return $null
}

function Get-ImagerVersion {
    param([string]$Path)
    $raw = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
    if (-not $raw) { return $null }
    $v = $null
    if ([version]::TryParse(($raw -split ' ')[0], [ref]$v)) { return $v }
    return $null
}

function Install-Imager {
    $dir = $script:DownloadDir
    if (-not $dir) { $dir = Join-Path $PSScriptRoot 'downloads' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $latest = Get-ImagerLatestVersion
    $fileName = if ($latest) { "imager_$latest.exe" } else { 'imager_latest.exe' }
    $installer = Join-Path $dir $fileName
    if (-not (Test-Path -LiteralPath $installer) -or (Get-Item -LiteralPath $installer).Length -eq 0) {
        Invoke-Download -Url 'https://downloads.raspberrypi.com/imager/imager_latest.exe' -OutFile $installer
    }
    Write-Step "Installing Raspberry Pi Imager from $installer (silent)"
    $p = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        Fail "Raspberry Pi Imager installer failed with exit code $($p.ExitCode). The cached installer was removed; re-run to download it again."
    }
    $Script:ImagerInstalledByScript = $true
}

function Uninstall-Imager {
    # Remove the Imager that this script installed, leaving the host clean.
    # Inno Setup places unins000.exe next to rpi-imager.exe.
    $exe = Get-ImagerPath
    if (-not $exe) { Write-Warn 'Raspberry Pi Imager binary no longer found; nothing to uninstall.'; return }
    $uninstaller = Join-Path (Split-Path -Parent $exe) 'unins000.exe'
    if (-not (Test-Path -LiteralPath $uninstaller)) {
        Write-Warn "Imager uninstaller not found at $uninstaller; leaving the installation in place."
        return
    }
    Write-Step "Uninstalling Raspberry Pi Imager (silent)"
    $p = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Warn "Raspberry Pi Imager uninstaller exited with code $($p.ExitCode)."
    }
    $dir = $script:DownloadDir
    if (-not $dir) { $dir = Join-Path $PSScriptRoot 'downloads' }
    Get-ChildItem -LiteralPath $dir -Filter 'imager_*.exe' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Find-Imager {
    if ($ImagerExe) {
        $p = Get-ImagerPath
        if ($p) { return $p }
        Fail "Raspberry Pi Imager not found at: $ImagerExe"
    }
    if (-not $SkipImagerInstall) {
        $p        = Get-ImagerPath
        $latest   = Get-ImagerLatestVersion
        $installed = if ($p) { Get-ImagerVersion $p } else { $null }
        if ($p -and $installed -and $latest -and $installed -ge $latest) {
            Write-Step "Raspberry Pi Imager is up to date (v$latest)."
            return $p
        }
        Install-Imager
    }
    $p = Get-ImagerPath
    if ($p) { return $p }
    Fail 'Raspberry Pi Imager not found. Install it from https://www.raspberrypi.com/software/ and re-run.'
}

function Get-LatestRelease {
    try {
        $html = (Invoke-WebRequest -UseBasicParsing -Uri "$Script:BaseUri/images/").Content
        $dates = [regex]::Matches($html, 'raspios_lite_arm64-(\d{4}-\d{2}-\d{2})/') |
                 ForEach-Object { $_.Groups[1].Value }
        if ($dates.Count -eq 0) { return $Script:DefaultRelease }
        return "raspios_lite_arm64-$((($dates | Sort-Object) | Select-Object -Last 1))"
    } catch {
        Write-Warn "Could not query the image archive ($($_.Exception.Message)); using pinned release $Script:DefaultRelease."
        return $Script:DefaultRelease
    }
}

function Get-ReleaseFiles {
    param([string]$Release)
    try {
        $html = (Invoke-WebRequest -UseBasicParsing -Uri "$Script:BaseUri/images/$Release/").Content
        $img = [regex]::Match($html, 'href="([^"]+\.img\.xz)"').Groups[1].Value
        if (-not $img) { return $null }
        $sha = [regex]::Match($html, 'href="([^"]+\.img\.xz\.sha256)"').Groups[1].Value
        return @{ Image = $img; Sha = $sha }
    } catch {
        return $null
    }
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    Write-Info "Downloading $([System.IO.Path]::GetFileName($OutFile))"
    & curl.exe -L --fail --silent --show-error --output $OutFile $Url
    if ($LASTEXITCODE -ne 0) { Fail "Download failed: $Url" }
}

function Get-Image {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }

    $release = Get-LatestRelease
    $files   = Get-ReleaseFiles $release
    if (-not $files) {
        $files = @{ Image = $Script:DefaultImage; Sha = "$Script:DefaultImage.sha256" }
        Write-Warn "Could not parse the release listing; falling back to pinned file $($files.Image)."
    }

    $imgPath = Join-Path $Dir $files.Image
    $shaPath = Join-Path $Dir $files.Sha

    if (-not (Test-Path -LiteralPath $imgPath)) {
        Invoke-Download -Url "$Script:BaseUri/images/$release/$($files.Image)" -OutFile $imgPath
    } else {
        Write-Info "Using cached image: $imgPath"
    }
    if (-not (Test-Path -LiteralPath $shaPath)) {
        Invoke-Download -Url "$Script:BaseUri/images/$release/$($files.Sha)" -OutFile $shaPath
    }

    $expected = ((Get-Content -LiteralPath $shaPath -TotalCount 1) -split ' ')[0].Trim()
    if (-not $expected) { Fail "Could not read the expected checksum from $shaPath" }

    Write-Step "Verifying SHA-256 of $($files.Image)"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $imgPath).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) {
        Fail "SHA-256 mismatch for $imgPath`n  expected: $expected`n  actual:   $actual"
    }
    return @{ Path = $imgPath; Hash = $expected.ToLowerInvariant() }
}

function Select-Disk {
    param([int]$Requested)

    $disks = Get-Disk | Where-Object {
        ($_.IsRemovable -or $_.BusType -in @('SD', 'eMMC')) -and -not $_.IsSystem
    } | Sort-Object Number

    if ($disks.Count -eq 0) {
        Write-Warn 'No removable SD/USB disk detected. Make sure your card reader is plugged in and the card is inserted.'
        $disks = Get-Disk | Where-Object { -not $_.IsSystem } | Sort-Object Number
        if ($disks.Count -eq 0) { Fail 'No writable disks found.' }
    }

    if ($Requested -ge 0) {
        $disk = $disks | Where-Object Number -eq $Requested
        if (-not $disk) { Fail "Disk $Requested not found among removable disks." }
        return $disk
    }

    Write-Info 'Detected candidate disks:'
    $i = 1
    foreach ($d in $disks) {
        $sizeGb = [math]::Round($d.Size / 1GB, 1)
        Write-Host ("  {0}) PhysicalDrive{1}  {2,-24} {3,6} GB  ({4})" -f $i, $d.Number, $d.FriendlyName, $sizeGb, $d.BusType)
        $i++
    }
    $sel = Read-Host "Select disk to overwrite (1-$($disks.Count))"
    if ($sel -notmatch '^\d+$') { Fail 'Invalid selection.' }
    $idx = [int]$sel - 1
    if ($idx -lt 0 -or $idx -ge $disks.Count) { Fail 'Invalid selection.' }
    $disk = $disks[$idx]

    $confirm = Read-Host "Type 'yes' to DESTROY all data on PhysicalDrive$($disk.Number) ($($disk.FriendlyName))"
    if ($confirm -ne 'yes') { Fail 'Aborted.' }
    return $disk
}

function Invoke-Flash {
    param([object]$Disk, [string]$ImagePath, [string]$Hash, [string]$Imager)
    $device = "\\.\PhysicalDrive$($Disk.Number)"
    Write-Step "Flashing $([System.IO.Path]::GetFileName($ImagePath)) to $device (this takes a few minutes)"
    if ($Hash) {
        & $Imager --cli --sha256 $Hash --disable-telemetry $ImagePath $device
    } else {
        & $Imager --cli --disable-telemetry $ImagePath $device
    }
    if ($LASTEXITCODE -ne 0) { Fail "Raspberry Pi Imager failed with exit code $LASTEXITCODE." }
}

function Find-OpenSsl {
    $c = Get-Command openssl -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $paths = @(
        "$env:ProgramFiles\Git\usr\bin\openssl.exe",
        "$env:ProgramFiles(x86)\Git\usr\bin\openssl.exe",
        "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe"
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function New-CryptHash {
    param([string]$Password)
    $ssl = Find-OpenSsl
    if (-not $ssl) {
        Fail 'openssl not found. Install Git for Windows (ships openssl), or re-run with -SkipCustomize.'
    }
    $saltChars = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    $salt = -join (1..16 | ForEach-Object { $saltChars[(Get-Random -Maximum $saltChars.Length)] })
    $hash = ($Password | & $ssl passwd -6 -stdin -salt $salt | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $hash -notmatch '^\$6\$') { Fail 'openssl passwd failed to create the password hash.' }
    return $hash
}

function Get-Credentials {
    param([string]$UserName, [string]$Password)
    if (-not $UserName) {
        $UserName = Read-Host 'Username to create on the Pi'
        if (-not $UserName) { Fail 'Username required.' }
    }
    if ($UserName -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        Fail "Invalid username '$UserName'. Use 1-32 lowercase letters, digits, '_' or '-'."
    }
    if (-not $Password) {
        $sec = Read-Host -AsSecureString 'Password for the Pi user (input is hidden)'
        if (-not $sec -or $sec.Length -eq 0) { Fail 'Password required.' }
        $ptr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
    if ($Password -match ':' -or $Password -match '[^\x21-\x7E]') {
        Fail 'Password must be ASCII and must not contain a colon (":").'
    }
    if ($Password.Length -lt 8) { Write-Warn 'Password is shorter than 8 characters - consider a stronger one.' }
    return @{ User = $UserName; Pass = $Password }
}

function Get-BootRoot {
    param([int]$DiskNumber)
    for ($i = 0; $i -lt 30; $i++) {
        if ($i -gt 0) { Start-Sleep -Seconds 2 }
        try {
            foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.FileSystemType -eq 'FAT32' })) {
                $p = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction SilentlyContinue
                if ($p -and $p.DiskNumber -eq $DiskNumber -and $p.Size -lt 2GB) { return "$($v.DriveLetter):\" }
            }
            $part = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
                    Sort-Object Size | Select-Object -First 1
            if ($part -and $part.Size -lt 4GB) {
                if ($part.DriveLetter) { return "$($part.DriveLetter):\" }
                $used  = Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter |
                         ForEach-Object { [string]$_.DriveLetter }
                $letter = ('D'..'Z' | Where-Object { [string]$_ -notin $used } | Select-Object -First 1)
                if (-not $letter) { Fail 'No free drive letter available to mount the boot partition.' }
                Set-Partition -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter
                Start-Sleep -Seconds 2
                return "${letter}:\"
            }
        } catch { }
    }
    return $null
}

function Add-FirstBootFiles {
    param([int]$DiskNumber, [string]$UserName, [string]$Password)
    Write-Step 'Enabling SSH and creating the login user for headless first boot'
    $root = Get-BootRoot $DiskNumber
    if (-not $root) { Fail 'Could not locate the boot partition after flashing.' }

    New-Item -ItemType File -Path (Join-Path $root 'ssh') -Force | Out-Null

    $hash = New-CryptHash $Password
    $userConf = Join-Path $root 'userconf.txt'
    [System.IO.File]::WriteAllText($userConf, "$UserName`:$hash`n")

    Write-Step "Wrote to $root : 'ssh' (empty) and 'userconf.txt' (user '$UserName')"
    Write-Info 'On first boot the Pi creates the account and deletes both files.'
}

# --- main -------------------------------------------------------------

if (-not (Test-Admin)) {
    Fail 'Please run this script as Administrator (right-click PowerShell > "Run as administrator").'
}

if (-not $DownloadDir) { $DownloadDir = Join-Path $PSScriptRoot 'downloads' }

$imager = Find-Imager
Write-Step "Using Raspberry Pi Imager: $imager"

if ($Image) {
    if (-not (Test-Path -LiteralPath $Image)) { Fail "Image not found: $Image" }
    Write-Step "Using image: $Image"
    $img = @{ Path = $Image; Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Image).Hash.ToLowerInvariant() }
} elseif ($SkipDownload) {
    $cached = Get-ChildItem -LiteralPath $DownloadDir -Filter '*.img.xz' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $cached) { Fail "No cached image found in $DownloadDir (and -SkipDownload was given)." }
    Write-Step "Using cached image: $($cached.FullName)"
    $img = @{ Path = $cached.FullName; Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cached.FullName).Hash.ToLowerInvariant() }
} else {
    $img = Get-Image $DownloadDir
}

$disk = Select-Disk $Disk

Invoke-Flash -Disk $disk -ImagePath $img.Path -Hash $img.Hash -Imager $imager

if (-not $SkipCustomize) {
    $cred = Get-Credentials -UserName $UserName -Password $Password
    Add-FirstBootFiles -DiskNumber $disk.Number -UserName $cred.User -Password $cred.Pass
}

if ($Script:ImagerInstalledByScript) {
    Uninstall-Imager
}

Write-Step 'Done. Safely eject the SD card, insert it into the Pi, and power on.'
if (-not $SkipCustomize) {
    Write-Host ''
    Write-Info 'After the Pi has booted (give it ~1-2 minutes on first boot), connect over SSH:'
    Write-Host ("    ssh {0}@raspberrypi.local" -f $cred.User)
    Write-Info 'Then on the Pi:'
    Write-Host '    git clone https://github.com/Chriszly/rpi-setup.git'
    Write-Host '    cd rpi-setup && sudo bash setup.sh'
}
