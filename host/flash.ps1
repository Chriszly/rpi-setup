#!/usr/bin/env pwsh
# flash.ps1 - Prepare an SD card for a headless Raspberry Pi (Windows host).
#
#   * downloads the latest Raspberry Pi OS Lite (arm64, 64-bit) image
#   * verifies its SHA-256 checksum
#   * writes it to an SD card with Raspberry Pi Imager
#   * enables SSH and creates a login user (headless first boot)
#
# If Raspberry Pi Imager is missing or outdated, the latest installer is
# downloaded and installed silently (unless -SkipImagerInstall). Once the run
# finishes - successfully or not - the Imager installed or upgraded by this
# script is uninstalled again, including any pre-existing installation it
# replaced, leaving the host clean. Also requires openssl (bundled with Git
# for Windows) unless -SkipCustomize.
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
    [switch]$SkipImagerInstall,
    # Permit flashing a non-removable disk by number. Off by default; used by CI,
    # which runs this setup flow against a virtual SD card (a mounted VHDX) on an
    # isolated runner. Interactive selection still only offers removable SD/USB.
    [switch]$AllowVirtualDisk
)

$ErrorActionPreference = 'Stop'

# Wall-clock timer for the whole run; Write-Step stamps every progress line
# with the elapsed time so CI logs show how long each phase took.
$Script:Timer = [System.Diagnostics.Stopwatch]::StartNew()

$Script:BaseUri        = 'https://downloads.raspberrypi.com/raspios_lite_arm64'
$Script:ImagerInstalledByScript = $false   # set when Install-Imager runs; triggers removal of the Imager
                                            # it installed/upgraded (including any pre-existing install)

function Write-Step {
    param([string]$m)
    $elapsed = if ($Script:Timer) { ' [{0:hh\:mm\:ss}]' -f $Script:Timer.Elapsed } else { '' }
    Write-Host "[+]$elapsed $m" -ForegroundColor Green
}
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
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager-cli.cmd",
        "$env:ProgramFiles(x86)\Raspberry Pi Ltd\Imager\rpi-imager.exe",
        "$env:ProgramFiles\Raspberry Pi Ltd\Imager\rpi-imager.exe",
        "$env:ProgramFiles(x86)\Raspberry Pi Ltd\Imager\rpi-imager-cli.cmd",
        "$env:ProgramFiles\Raspberry Pi Ltd\Imager\rpi-imager-cli.cmd"
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
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    foreach ($raw in @($info.ProductVersion, $info.FileVersion, $info.InformationalVersion)) {
        if (-not $raw) { continue }
        $v = $null
        if ([version]::TryParse(($raw -replace '^[vV]' -split ' ')[0], [ref]$v)) { return $v }
    }
    return $null
}

function Clear-ImagerCache {
    param([string]$Dir)
    # Remove every cached Imager installer so a later run starts clean and can
    # never reuse a stale or partial artifact after a failed install/uninstall.
    Get-ChildItem -LiteralPath $Dir -Filter 'imager_*.exe' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-LogTail {
    param([string]$Log)
    if (Test-Path -LiteralPath $Log) {
        Write-Warn "Last lines of $($Log):"
        Get-Content -LiteralPath $Log -Tail 25 | ForEach-Object { Write-Host "    $_" }
    }
}

function Invoke-WatchedProcess {
    # Run an installer and wait with a heartbeat and a hard timeout. A stalled
    # silent install (e.g. the Imager's pnputil driver step blocking forever on
    # a headless CI runner) must fail fast with diagnostics instead of hanging
    # until an outer job timeout kills it.
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string[]]$ArgumentList,
        [Parameter(Mandatory)] [string]$Label,
        [int]$TimeoutSeconds = 300
    )
    $p  = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Info "$Label running (pid $($p.Id)); heartbeat every 15s, hard timeout ${TimeoutSeconds}s"
    while ($true) {
        if ($p.HasExited) { return $p.ExitCode }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warn "$Label timed out after ${TimeoutSeconds}s - killing its process tree..."
            & taskkill /T /F /PID $p.Id 2>$null | Out-Null
            throw "$Label did not finish within ${TimeoutSeconds}s and was killed (started from '$FilePath'). Its log shows which step stalled."
        }
        Start-Sleep -Seconds 15
        if (-not $p.HasExited) {
            Write-Host ("[*] {0} still running ({1:mm\:ss} elapsed)" -f $Label, $sw.Elapsed) -ForegroundColor Cyan
        }
    }
}

function Install-Imager {
    $dir = $script:DownloadDir
    if (-not $dir) { $dir = Join-Path $PSScriptRoot 'downloads' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $latest = Get-ImagerLatestVersion
    $fileName = if ($latest) { "imager_$latest.exe" } else { 'imager_latest.exe' }
    $installer = Join-Path $dir $fileName
    if (-not (Test-Path -LiteralPath $installer) -or (Get-Item -LiteralPath $installer).Length -eq 0) {
        Write-Step "Downloading Raspberry Pi Imager installer..."
        Invoke-Download -Url 'https://downloads.raspberrypi.com/imager/imager_latest.exe' -OutFile $installer
    }

    # /LOG gives a full transcript of the install; when the installer stalls
    # (its pnputil driver step is known to hang on headless CI runners) the log
    # shows exactly where, and CI uploads it as an artifact.
    $log = Join-Path $dir 'imager-install.log'
    Write-Step "Installing Raspberry Pi Imager from $installer (silent)..."
    try {
        $code = Invoke-WatchedProcess -FilePath $installer `
            -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$log`"") `
            -Label 'Raspberry Pi Imager installer' -TimeoutSeconds 120
    } catch {
        # Watchdog timed out (pnputil hung in [Run] section). The file copy phase
        # already succeeded; check if the binary was installed.
        Write-Warn "Installer watchdog timed out; checking for installed binary..."
        $installedExe = Get-ImagerPath
        if ($installedExe) {
            Write-Step "Imager binary found at $installedExe despite watchdog timeout"
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
            $Script:ImagerInstalledByScript = $true
            return
        }
        Write-LogTail $log
        Clear-ImagerCache -Dir $dir
        Fail $_.Exception.Message
    }
    if ($code -ne 0) {
        Write-LogTail $log
        Clear-ImagerCache -Dir $dir
        Fail "Raspberry Pi Imager installer failed with exit code $code. Cached installers were removed; re-run to download again."
    }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    Write-Step "Raspberry Pi Imager installed successfully"
    $Script:ImagerInstalledByScript = $true
}

function Uninstall-Imager {
    # Remove the Imager that this script installed (or upgraded, if a
    # pre-existing installation was outdated), leaving the host clean.
    # Inno Setup places unins000.exe next to rpi-imager.exe.
    $dir = $script:DownloadDir
    if (-not $dir) { $dir = Join-Path $PSScriptRoot 'downloads' }
    try {
        $exe = Get-ImagerPath
        if (-not $exe) { Write-Warn 'Raspberry Pi Imager binary no longer found; nothing to uninstall.'; return }
        $uninstaller = Join-Path (Split-Path -Parent $exe) 'unins000.exe'
        if (-not (Test-Path -LiteralPath $uninstaller)) {
            Write-Warn "Imager uninstaller not found at $uninstaller; leaving the installation in place."
            return
        }
        Write-Step "Uninstalling Raspberry Pi Imager (silent)"
        $uninstallLog = Join-Path $dir 'imager-uninstall.log'
        $code = Invoke-WatchedProcess -FilePath $uninstaller `
            -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$uninstallLog`"") `
            -Label 'Raspberry Pi Imager uninstaller' -TimeoutSeconds 60
        if ($code -ne 0) {
            Write-Warn "Raspberry Pi Imager uninstaller exited with code $code."
        }
    } catch {
        # A cleanup problem must never turn a successful run into a failure or
        # mask the error the run actually failed with - report and carry on.
        Write-Warn "Could not uninstall Raspberry Pi Imager: $($_.Exception.Message)"
    } finally {
        # The cache is always cleared - even if the uninstaller was missing or
        # failed - so a later run cannot reuse stale or partial artifacts.
        Clear-ImagerCache -Dir $dir
    }
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
        if ($dates.Count -eq 0) { Fail "Could not determine latest release from archive listing. Use -Image to specify a local image." }
        return "raspios_lite_arm64-$((($dates | Sort-Object) | Select-Object -Last 1))"
    } catch {
        Fail "Could not query the image archive ($($_.Exception.Message)). Check network connectivity or use -Image to specify a local image."
    }
}

function Get-ReleaseFiles {
    param([string]$Release)
    try {
        $html = (Invoke-WebRequest -UseBasicParsing -Uri "$Script:BaseUri/images/$Release/").Content
        $img = [regex]::Match($html, 'href="([^"]+\.img\.xz)"').Groups[1].Value
        if (-not $img) { Fail "Could not parse release listing for $Release. Use -Image to specify a local image." }
        $sha = [regex]::Match($html, 'href="([^"]+\.img\.xz\.sha256)"').Groups[1].Value
        return @{ Image = $img; Sha = $sha }
    } catch {
        Fail "Could not fetch release files for $Release ($($_.Exception.Message))."
    }
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    Write-Step "Downloading $([System.IO.Path]::GetFileName($OutFile))"
    & curl.exe -L --fail --progress-bar --output $OutFile $Url
    if ($LASTEXITCODE -ne 0) { Fail "Download failed: $Url" }
    Write-Step "Downloaded $([System.IO.Path]::GetFileName($OutFile))"
}

function Get-Image {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }

    Write-Step "Querying latest Raspberry Pi OS release..."
    $release = Get-LatestRelease
    Write-Step "Latest release: $release"

    Write-Step "Fetching release file listing..."
    $files   = Get-ReleaseFiles $release

    $imgPath = Join-Path $Dir $files.Image
    $shaPath = Join-Path $Dir $files.Sha

    if (-not (Test-Path -LiteralPath $imgPath)) {
        Write-Step "Downloading OS image ($($files.Image))..."
        Invoke-Download -Url "$Script:BaseUri/images/$release/$($files.Image)" -OutFile $imgPath
    } else {
        Write-Step "Using cached OS image: $imgPath"
    }
    if (-not (Test-Path -LiteralPath $shaPath)) {
        Write-Step "Downloading checksum file ($($files.Sha))..."
        Invoke-Download -Url "$Script:BaseUri/images/$release/$($files.Sha)" -OutFile $shaPath
    }

    $expected = ((Get-Content -LiteralPath $shaPath -TotalCount 1) -split ' ')[0].Trim()
    if (-not $expected) { Fail "Could not read the expected checksum from $shaPath" }

    Write-Step "Verifying SHA-256 of $($files.Image)..."
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $imgPath).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) {
        Fail "SHA-256 mismatch for $imgPath`n  expected: $expected`n  actual:   $actual"
    }
    Write-Step "SHA-256 verification passed"
    return @{ Path = $imgPath; Hash = $expected.ToLowerInvariant() }
}

function Test-FlashableDisk {
    param($Disk, [bool]$AllowVirtual = $false)
    # A disk is flashable when it is a removable SD/USB/eMMC card, or - with
    # -AllowVirtualDisk (CI mode) - any non-system disk such as a mounted VHDX
    # virtual SD card on an isolated test runner. The system disk is never
    # flashable.
    -not $Disk.IsSystem -and ($AllowVirtual -or $Disk.IsRemovable -or $Disk.BusType -in @('SD', 'eMMC'))
}

function Select-Disk {
    param([int]$Requested)

    $disks = Get-Disk | Where-Object { Test-FlashableDisk $_ ([bool]$AllowVirtualDisk) } | Sort-Object Number

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
    Write-Step "Flashing $([System.IO.Path]::GetFileName($ImagePath)) to $device (this takes several minutes)..."
    $cliArgs = @('--cli', '--disable-telemetry')
    if ($AllowVirtualDisk) {
        # CI mode: the target is a mounted VHDX, which Imager does not consider
        # removable and would otherwise reject (or eject after writing). The disk
        # must stay attached so the boot partition can be set up afterwards.
        $cliArgs += @('--enable-writing-system-drives', '--disable-eject')
    }
    if ($Hash) { $cliArgs += '--sha256', $Hash }
    & $Imager @cliArgs $ImagePath $device
    if ($LASTEXITCODE -ne 0) { Fail "Raspberry Pi Imager failed with exit code $LASTEXITCODE." }
    Write-Step "Flash completed successfully"
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
    # Virtual disks (CI) need more retries because Windows doesn't auto-rescan
    # the partition table after a raw write as reliably as physical media.
    $maxRetries = if ($AllowVirtualDisk) { 60 } else { 30 }
    for ($i = 0; $i -lt $maxRetries; $i++) {
        if ($i -gt 0) { Start-Sleep -Seconds 2 }
        try {
            # Best-effort: re-read the partition table the flasher just wrote.
            # Not strictly needed on real cards, but required for virtual SD
            # disks (CI), which Windows does not auto-rescan after a raw write.
            Update-HostStorageCache | Out-Null
            # Extra nudge for virtual disks: force a disk rescan
            if ($AllowVirtualDisk) {
                Get-Disk -Number $DiskNumber | Update-Disk | Out-Null
            }
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

try {
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

    Write-Step "Selecting target disk..."
    $targetDisk = Select-Disk $Disk

    Write-Step "Starting flash operation..."
    Invoke-Flash -Disk $targetDisk -ImagePath $img.Path -Hash $img.Hash -Imager $imager

    if (-not $SkipCustomize) {
        Write-Step "Configuring first-boot files (SSH + user)..."
        $cred = Get-Credentials -UserName $UserName -Password $Password
        Add-FirstBootFiles -DiskNumber $targetDisk.Number -UserName $cred.User -Password $cred.Pass
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
}
finally {
    # Cleanup is never skipped: once the script installed Imager, it is
    # removed on success AND on any failure - including any pre-existing
    # installation it upgraded - and the cached installers are cleared, so the
    # next run starts clean without stale artifacts.
    if ($Script:ImagerInstalledByScript) { Uninstall-Imager }
}
