#!/usr/bin/env pwsh
# flash.ps1 - Prepare an SD card for a headless Raspberry Pi (Windows host).
#
#   * downloads the latest Raspberry Pi OS Lite (arm64, 64-bit) image
#   * verifies its SHA-256 checksum
#   * writes it to an SD card with Raspberry Pi Imager
#   * enables SSH and creates a login user (headless first boot)
#   * optionally sets hostname, Wi-Fi and an SSH public key, and creates a new
#     SSH key for the Pi to use with GitHub (printed at the end; the private
#     key goes only onto the card)
#
# Any installed Raspberry Pi Imager is used. If none is installed, the latest
# installer is downloaded and installed silently (unless -SkipImagerInstall).
# Once the run finishes - successfully or not - an Imager installed by this
# script is uninstalled again, leaving the host clean. Also requires openssl
# (bundled with Git for Windows) unless -SkipCustomize.
# Run in an elevated PowerShell. See README.md for the full workflow.
#
# Examples:
#   .\host\flash.ps1                              # asks for everything, lists the disks, ejects the card
#   .\host\flash.ps1 -Disk 2 -UserName pi -Password 'changeme'   # still asks "yes"
#   .\host\flash.ps1 -Disk 2 -Force ...                          # unattended
#   .\host\flash.ps1 -Image C:\dl\raspios.img.xz # use an image you already have
#   .\host\flash.ps1 -Hostname homepi -WifiSsid 'My WiFi' -SshPublicKeyFile $HOME\.ssh\id_ed25519.pub
#
# The optional first-boot settings (hostname, Wi-Fi, SSH key) are written as
# cloud-init files on Trixie images and as a one-time firstrun.sh on Bookworm.
# They can also come from FLASH_* environment variables or the FLASH_* lines of
# config\rpi-setup.env (nothing else in that file is read).
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
    # Skip SSH/user pre-configuration (boot to the on-screen setup wizard instead).
    [switch]$SkipCustomize,
    # Do not auto-install Raspberry Pi Imager; fail if it is missing.
    [switch]$SkipImagerInstall,
    # Skip the "type 'yes' to DESTROY" confirmation. Only for unattended runs
    # together with -Disk; the wrong number wipes the wrong disk without asking.
    [switch]$Force,
    # Leave the card mounted at the end instead of ejecting it.
    [switch]$NoEject,
    # First-boot settings (optional). Each falls back to the FLASH_* environment
    # variable of the same meaning, then to config\rpi-setup.env.
    # Host name, e.g. homepi (reachable as homepi.local).
    [string]$Hostname,
    # Wi-Fi network to join on first boot, and its password (prompted if omitted).
    [string]$WifiSsid,
    [string]$WifiPassword,
    # Wi-Fi country code (regulatory domain). Default: DE
    [string]$WifiCountry,
    # SSH public key file to authorize for the user, e.g. $HOME\.ssh\id_ed25519.pub
    [string]$SshPublicKeyFile,
    # Create a new SSH key for the Pi to use with GitHub: yes or no. Default when
    # run at a console: yes, without asking.
    [string]$GitHubKey
)

$ErrorActionPreference = 'Stop'

$Script:BaseUri        = 'https://downloads.raspberrypi.com/raspios_lite_arm64'
$Script:ImagerInstalledByScript = $false   # set when Install-Imager runs; triggers removal of the Imager it installed

function Write-Step { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail       { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function Get-ImagerPath {
    $candidates = @()
    $cmd = Get-Command rpi-imager.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @(
        "${env:ProgramFiles(x86)}\Raspberry Pi Imager\rpi-imager.exe",
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe",
        "$env:LOCALAPPDATA\Raspberry Pi Imager\rpi-imager.exe",
        "$env:LOCALAPPDATA\Programs\Raspberry Pi Imager\rpi-imager.exe",
        "${env:ProgramFiles(x86)}\Raspberry Pi Ltd\Imager\rpi-imager.exe",
        "$env:ProgramFiles\Raspberry Pi Ltd\Imager\rpi-imager.exe"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
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

function Install-Imager {
    $dir = $script:DownloadDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $installer = Join-Path $dir 'imager_latest.exe'
    Invoke-Download -Url 'https://downloads.raspberrypi.com/imager/imager_latest.exe' -OutFile $installer
    Write-Step "Installing Raspberry Pi Imager from $installer (silent)"
    $p = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Clear-ImagerCache -Dir $dir
        Fail "Raspberry Pi Imager installer failed with exit code $($p.ExitCode). Cached installers were removed; re-run to download again."
    }
    $Script:ImagerInstalledByScript = $true
}

function Uninstall-Imager {
    # Remove the Imager that this script installed, leaving the host clean.
    # Inno Setup places unins000.exe next to rpi-imager.exe.
    $dir = $script:DownloadDir
    try {
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
    # Any installed Imager will do; install one only when there is none.
    if (-not (Get-ImagerPath) -and -not $SkipImagerInstall) { Install-Imager }
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
    Write-Info "Downloading $([System.IO.Path]::GetFileName($OutFile))"
    # Download to a .part file and move it into place only when complete, so an
    # interrupted transfer never leaves a file that looks finished.
    $part = "$OutFile.part"
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    & curl.exe -L --fail --silent --show-error --output $part $Url
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        Fail "Download failed: $Url. Check network connectivity and re-run."
    }
    Move-Item -LiteralPath $part -Destination $OutFile -Force
}

function Get-Image {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }

    $release = Get-LatestRelease
    $files   = Get-ReleaseFiles $release

    $imgPath = Join-Path $Dir $files.Image
    $shaPath = Join-Path $Dir $files.Sha

    # The checksum file is tiny: fetch it fresh on every run, so a truncated or
    # stale copy can never fail the check forever.
    Invoke-Download -Url "$Script:BaseUri/images/$release/$($files.Sha)" -OutFile $shaPath
    $expected = ((Get-Content -LiteralPath $shaPath -TotalCount 1) -split ' ')[0].Trim().ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        Remove-Item -LiteralPath $shaPath -Force
        Fail "$($files.Sha) is not a SHA-256 checksum file. Re-run later or use -Image."
    }

    # A cached image that fails the check (e.g. left by an interrupted download
    # of an older version of this script) is deleted and downloaded once more.
    foreach ($cached in @($true, $false)) {
        if ($cached) {
            if (-not (Test-Path -LiteralPath $imgPath)) { continue }
            Write-Info "Using cached image: $imgPath"
        } else {
            Invoke-Download -Url "$Script:BaseUri/images/$release/$($files.Image)" -OutFile $imgPath
        }
        Write-Step "Verifying SHA-256 of $($files.Image)"
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $imgPath).Hash.ToLowerInvariant()
        if ($actual -eq $expected) { return @{ Path = $imgPath; Hash = $expected } }
        Remove-Item -LiteralPath $imgPath -Force
        if ($cached) { Write-Warn 'Cached image failed the SHA-256 check (interrupted download?); deleted it, downloading again.' }
    }
    Remove-Item -LiteralPath $shaPath -Force
    Fail "SHA-256 mismatch for $($files.Image) (deleted the download)`n  expected: $expected`n  actual:   $actual`nRe-run the script to download it afresh."
}

# The drive letters and labels on disk $Number, e.g. "  D: SDCARD", to help
# recognise the card in the list; empty when it has none.
function Get-DiskVolumeText {
    param([int]$Number)
    $names = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object {
        $label = (Get-Volume -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue).FileSystemLabel
        ("{0}: {1}" -f $_.DriveLetter, $label).Trim()
    })
    if ($names.Count -eq 0) { return '' }
    return '  ' + ($names -join ', ')
}

function Select-Disk {
    param([int]$Requested)

    # Get-Disk has no IsRemovable property; card readers show up as BusType USB,
    # SD or MMC. Size 0 is an empty slot of a multi-slot reader.
    $disks = @(Get-Disk | Where-Object {
        $_.BusType -in @('USB', 'SD', 'MMC') -and -not $_.IsSystem -and -not $_.IsBoot -and $_.Size -gt 0
    } | Sort-Object Number)

    if ($disks.Count -eq 0) {
        Write-Warn 'No removable SD/USB disk detected. Make sure your card reader is plugged in and the card is inserted.'
        $disks = @(Get-Disk | Where-Object { -not $_.IsSystem -and -not $_.IsBoot -and $_.Size -gt 0 } | Sort-Object Number)
        if ($disks.Count -eq 0) { Fail 'No writable disks found.' }
    }

    if ($Requested -ge 0) {
        $disk = $disks | Where-Object Number -eq $Requested
        if (-not $disk) { Fail "Disk $Requested not found among removable disks." }
        Write-Info ("Target: PhysicalDrive{0}  {1}  {2} GB  ({3})" -f $disk.Number, $disk.FriendlyName, [math]::Round($disk.Size / 1GB, 1), $disk.BusType)
        if (-not $Force) { Confirm-Destroy $disk }
        return $disk
    }

    Write-Info 'Detected candidate disks:'
    $i = 1
    foreach ($d in $disks) {
        $sizeGb = [math]::Round($d.Size / 1GB, 1)
        Write-Host ("  {0}) PhysicalDrive{1}  {2,-24} {3,6} GB  ({4}){5}" -f $i, $d.Number, $d.FriendlyName, $sizeGb, $d.BusType, (Get-DiskVolumeText $d.Number))
        $i++
    }
    $sel = Read-Host "Select disk to overwrite (1-$($disks.Count))"
    if ($sel -notmatch '^\d+$') { Fail 'Invalid selection.' }
    $idx = [int]$sel - 1
    if ($idx -lt 0 -or $idx -ge $disks.Count) { Fail 'Invalid selection.' }
    $disk = $disks[$idx]
    Confirm-Destroy $disk
    return $disk
}

function Confirm-Destroy {
    param([object]$Disk)
    $confirm = Read-Host "Type 'yes' to DESTROY all data on PhysicalDrive$($Disk.Number) ($($Disk.FriendlyName))"
    if ($confirm -ne 'yes') { Fail 'Aborted.' }
}

# Start-Process joins -ArgumentList with spaces and does not quote, so quote
# anything that needs it (image paths under "C:\Users\First Last\...").
function ConvertTo-ArgumentString {
    param([string[]]$Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

function Invoke-Flash {
    param([object]$Disk, [string]$ImagePath, [string]$Imager)
    $device = "\\.\PhysicalDrive$($Disk.Number)"
    # --disable-telemetry is a GUI-only option: Imager's --cli parser rejects it
    # and exits before writing. --disable-eject keeps the card mounted so the
    # first-boot files can be written to its boot partition afterwards.
    # No --sha256: Imager 2.x compares it with the hash of the *uncompressed*
    # image, while the published checksum (already checked by Get-Image) is
    # that of the .img.xz, so passing it fails every write. Imager still reads
    # the card back and verifies what it wrote.
    $cliArgs = @('--cli', '--disable-eject')
    $cliArgs += @($ImagePath, $device)
    Write-Step "Flashing $([System.IO.Path]::GetFileName($ImagePath)) to $device (this takes a few minutes)"
    # rpi-imager.exe is built as a GUI application, so "& rpi-imager.exe ..."
    # returns the moment it has launched: $LASTEXITCODE is left stale (0) while
    # the write is still running, and the boot partition is not there yet when
    # we look for it. -Wait blocks until the process and its children have
    # exited; -PassThru gives us the real exit code.
    $p = Start-Process -FilePath $Imager -ArgumentList (ConvertTo-ArgumentString $cliArgs) -Wait -PassThru
    if ($p.ExitCode -ne 0) { Fail "Raspberry Pi Imager failed with exit code $($p.ExitCode)." }
}

function Find-OpenSsl {
    $c = Get-Command openssl -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $paths = @(
        "$env:ProgramFiles\Git\usr\bin\openssl.exe",
        "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe",
        "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe"
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

# Run "openssl passwd -6 -stdin" ($Salt adds -salt) with exactly $Password on
# stdin. Windows PowerShell feeds native programs through the console input
# encoding, which on a UTF-8 system (codepage 65001) starts with a byte order
# mark: "$Password | openssl ..." then hashed <BOM>password, a password no one
# can type at the Pi's login or sudo prompt. So the bytes are written raw,
# with the console input encoding set to UTF-8 without BOM meanwhile.
function Invoke-OpenSslPasswd {
    param([string]$OpenSsl, [string]$Password, [string]$Salt)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $OpenSsl
    $psi.Arguments = 'passwd -6 -stdin'
    if ($Salt) { $psi.Arguments = "passwd -6 -salt $Salt -stdin" }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $savedEncoding = $null
    try { $savedEncoding = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $savedEncoding = $null }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } finally {
        if ($savedEncoding) { [Console]::InputEncoding = $savedEncoding }
    }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Password + "`n")
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd().Trim()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }
    return $out
}

function New-CryptHash {
    param([string]$Password)
    $ssl = Find-OpenSsl
    if (-not $ssl) {
        Fail 'openssl not found. Install Git for Windows (ships openssl), or re-run with -SkipCustomize.'
    }
    # Let openssl generate the salt (full 16 characters, crypto-grade randomness).
    $hash = Invoke-OpenSslPasswd -OpenSsl $ssl -Password $Password
    if ($hash -notmatch '^\$6\$') { Fail 'openssl passwd failed to create the password hash.' }
    return $hash
}

function Get-Credentials {
    param([string]$UserName, [string]$Password)
    if (-not $UserName) {
        $UserName = Read-Host 'Username to create on the Pi'
        if (-not $UserName) { Fail 'Username required.' }
    }
    # -cnotmatch: -notmatch ignores case and let 'piUser' through.
    if ($UserName -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        Fail "Invalid username '$UserName'. Use 1-32 lowercase letters, digits, '_' or '-'."
    }
    if (-not $Password) {
        $sec = Read-Host -AsSecureString 'Password for the Pi user (input is hidden)'
        if (-not $sec -or $sec.Length -eq 0) { Fail 'Password required.' }
        $Password = [Net.NetworkCredential]::new('', $sec).Password
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
    param([int]$DiskNumber, [string]$UserName, [string]$PasswordHash, [hashtable]$Settings)
    Write-Step 'Enabling SSH and creating the login user for headless first boot'
    $root = Get-BootRoot $DiskNumber
    if (-not $root) { Fail 'Could not locate the boot partition after flashing.' }

    New-Item -ItemType File -Path (Join-Path $root 'ssh') -Force | Out-Null

    $userConf = Join-Path $root 'userconf.txt'
    [System.IO.File]::WriteAllText($userConf, "$UserName`:$PasswordHash`n")

    if ($Settings) { Write-FirstBootSettings -Root $root -UserName $UserName -Settings $Settings }

    Write-Step "Wrote to $root : 'ssh' (empty) and 'userconf.txt' (user '$UserName')"
    Write-Info 'On first boot the Pi creates the account and deletes both files.'
}

# Eject the card on disk $DiskNumber: every volume on it is flushed, locked,
# dismounted and its media ejected (the reader stays). If that fails, the USB
# device itself is ejected, as "Safely Remove Hardware" does (a card reader
# then needs replugging). Returns $true when the card can be taken out; never
# fails the run.
$Script:EjectSource = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RpiSetupEject {
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out uint devInst, string deviceId, int flags);
    [DllImport("cfgmgr32.dll")]
    static extern int CM_Get_Parent(out uint parent, uint devInst, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Request_Device_EjectW(uint devInst, out int vetoType, StringBuilder vetoName, int nameLength, int flags);
    // Eject the device $instanceId (e.g. USBSTOR\DISK&...), else its parent
    // (the USB device). Returns "" on success, else why it was refused.
    public static string EjectDevice(string instanceId) {
        uint dev;
        int r = CM_Locate_DevNodeW(out dev, instanceId, 0);
        if (r != 0) return "device not found (" + r + ")";
        string why = "";
        for (int i = 0; i < 3; i++) {
            int veto;
            StringBuilder name = new StringBuilder(400);
            r = CM_Request_Device_EjectW(dev, out veto, name, name.Capacity, 0);
            if (r == 0 && veto == 0) return "";
            why = "refused (" + r + ", veto " + veto + (name.Length > 0 ? " by " + name : "") + ")";
            uint parent;
            if (CM_Get_Parent(out parent, dev, 0) != 0) break;
            dev = parent;
        }
        return why;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, IntPtr outBuf, int outSize, out int returned, IntPtr overlapped);
    static bool Ioctl(SafeFileHandle h, uint code, byte[] input) {
        int returned;
        return DeviceIoControl(h, code, input, input == null ? 0 : input.Length, IntPtr.Zero, 0, out returned, IntPtr.Zero);
    }
    // Returns "" on success, else the step that failed and the Win32 error.
    public static string Eject(char letter) {
        using (SafeFileHandle h = CreateFile(@"\\.\" + letter + ":", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return "open failed (" + Marshal.GetLastWin32Error() + ")";
            bool locked = false;
            for (int i = 0; i < 20 && !locked; i++) {
                locked = Ioctl(h, 0x00090018, null);                // FSCTL_LOCK_VOLUME
                if (!locked) System.Threading.Thread.Sleep(500);
            }
            if (!locked) return "volume in use (" + Marshal.GetLastWin32Error() + ")";
            if (!Ioctl(h, 0x00090020, null)) return "dismount failed (" + Marshal.GetLastWin32Error() + ")";   // FSCTL_DISMOUNT_VOLUME
            Ioctl(h, 0x002D4804, new byte[] { 0 });                    // IOCTL_STORAGE_MEDIA_REMOVAL: allow
            if (!Ioctl(h, 0x002D4808, null)) return "eject failed (" + Marshal.GetLastWin32Error() + ")";      // IOCTL_STORAGE_EJECT_MEDIA
            return "";
        }
    }
}
'@

function Dismount-Card {
    param([int]$DiskNumber)
    $letters = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
                 Where-Object DriveLetter | ForEach-Object { [char]$_.DriveLetter })
    try {
        if (-not ('RpiSetupEject' -as [type])) { Add-Type -TypeDefinition $Script:EjectSource -ErrorAction Stop }
        $err = ''
        foreach ($l in $letters) {
            Write-VolumeCache -DriveLetter $l -ErrorAction SilentlyContinue
            $err = [RpiSetupEject]::Eject($l)
            if ($err) { Write-Info "Media eject of ${l}: $err; ejecting the USB device instead."; break }
        }
        if ($letters.Count -gt 0 -and -not $err) { return $true }
        $id = (Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object Index -eq $DiskNumber).PNPDeviceID
        if (-not $id) { Write-Warn 'Could not find the card''s USB device. Eject it in Explorer before removing it.'; return $false }
        $usbErr = [RpiSetupEject]::EjectDevice($id)
        if ($usbErr) { Write-Warn "Could not eject the USB device: $usbErr. Eject it in Explorer before removing it."; return $false }
        return $true
    } catch {
        Write-Warn "Could not eject the card ($($_.Exception.Message)). Eject it in Explorer before removing it."
        return $false
    }
}

# --- first-boot settings: hostname, Wi-Fi, SSH key ----------------------------
# All optional. Each comes from its parameter, else the FLASH_* environment
# variable, else the FLASH_* line of config\rpi-setup.env. With none set the
# card gets exactly what it got before: 'ssh' and 'userconf.txt'.
# Mirrors host/flash.sh; ci/test-task-flash.sh tests the bash version.
$Script:FlashNames = @('FLASH_HOSTNAME', 'FLASH_WIFI_SSID', 'FLASH_WIFI_PASSWORD', 'FLASH_WIFI_COUNTRY', 'FLASH_SSH_PUBKEY_FILE', 'FLASH_GITHUB_KEY')
$Script:FlashKeyPattern = '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+AAAA[A-Za-z0-9+/]+={0,3}(\s.*)?$'
# sshd drop-in that makes sshd also read /etc/ssh/authorized_keys/<user>; keys
# there do not depend on when userconf.txt creates or renames the login user.
$Script:FlashSshdConf = '/etc/ssh/sshd_config.d/10-rpi-setup-authorized-keys.conf'
$Script:FlashSshdLine = 'AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 /etc/ssh/authorized_keys/%u'
# Clears the Wi-Fi rfkill block Raspberry Pi OS Lite keeps until a country is set.
$Script:FlashRfkillUnblock = 'rfkill unblock wifi; for f in /var/lib/systemd/rfkill/*:wlan; do [ -e "$f" ] && echo 0 >"$f"; done; true'
# The Pi's own GitHub key (FLASH_GITHUB_KEY=yes): created on this PC in a temp
# folder, copied to the boot partition as $FlashGitHubKeyFile (+ .pub) and
# deleted here. On the Pi a one-shot service moves it into the login user's
# ~/.ssh (mode 600, owned by the user) once that user exists, and deletes it
# from the boot partition. Mirrors host/flash.sh.
$Script:FlashGitHubKeyFile = 'rpi-setup-github-key'
$Script:FlashGitHubKeyScriptPath = '/usr/local/sbin/rpi-setup-github-key'
$Script:FlashGitHubKeyUnit = 'rpi-setup-github-key.service'
$Script:FlashGitHubKeyScriptBody = @(
    'BOOT=/boot/firmware',
    '[ -d "$BOOT" ] || BOOT=/boot',
    'KEY="$BOOT/rpi-setup-github-key"',
    '[ -f "$KEY" ] || exit 0',
    'H="$(getent passwd "$U" | cut -d: -f6)"',
    '# userconf.txt creates the login user; until it exists, try again next boot.',
    '[ -n "$H" ] && [ -d "$H" ] || exit 0',
    'G="$(id -gn "$U")"',
    'install -d -m 0700 -o "$U" -g "$G" "$H/.ssh"',
    'install -m 0600 -o "$U" -g "$G" "$KEY" "$H/.ssh/id_ed25519_github"',
    'install -m 0644 -o "$U" -g "$G" "$KEY.pub" "$H/.ssh/id_ed25519_github.pub"',
    'if ! grep -qs id_ed25519_github "$H/.ssh/config"; then',
    '  { echo "Host github.com"; echo "  IdentityFile ~/.ssh/id_ed25519_github"; echo "  IdentitiesOnly yes"; echo "  StrictHostKeyChecking accept-new"; } >>"$H/.ssh/config"',
    '  chown "$U:$G" "$H/.ssh/config"',
    '  chmod 0600 "$H/.ssh/config"',
    'fi',
    'rm -f "$KEY" "$KEY.pub"',
    'systemctl disable rpi-setup-github-key.service >/dev/null 2>&1 || true'
)
$Script:FlashGitHubKeyUnitLines = @(
    '[Unit]',
    'Description=Move the rpi-setup GitHub SSH key from the boot partition to the login user',
    'After=local-fs.target userconfig.service',
    'ConditionPathExists=|/boot/firmware/rpi-setup-github-key',
    'ConditionPathExists=|/boot/rpi-setup-github-key',
    '',
    '[Service]',
    'Type=oneshot',
    "ExecStart=$Script:FlashGitHubKeyScriptPath",
    '',
    '[Install]',
    'WantedBy=multi-user.target'
)

# The key-moving script for login user $UserName (a validated user name).
function Get-GitHubKeyScript {
    param([string]$UserName)
    return @(
        '#!/bin/sh',
        '# Written by rpi-setup host/flash.ps1: moves the GitHub SSH key from the boot',
        "# partition into the login user's ~/.ssh, then deletes it there.",
        "U='$UserName'"
    ) + $Script:FlashGitHubKeyScriptBody
}

# ssh-keygen.exe from Windows' OpenSSH client or Git for Windows, or $null.
function Find-SshKeygen {
    $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in @("$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe", "$env:ProgramFiles\Git\usr\bin\ssh-keygen.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# Create a new ed25519 key without passphrase in a fresh temp folder. Returns
# @{ Dir; Private; Public } (the caller deletes Dir once the key is on the card).
function New-GitHubKey {
    param([string]$Comment)
    $keygen = Find-SshKeygen
    if (-not $keygen) { Fail 'ssh-keygen not found. Install the Windows OpenSSH client or Git for Windows, or answer "no" to the GitHub key.' }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('rpi-setup-key-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $key = Join-Path $dir 'id_ed25519_github'
    # Start-Process takes the command line as written, so the empty passphrase
    # survives as "" (PowerShell 5.1 drops empty arguments to native programs).
    $argLine = '-q -t ed25519 -N "" -C "{0}" -f "{1}"' -f $Comment, $key
    $p = Start-Process -FilePath $keygen -ArgumentList $argLine -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$key.pub")) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Fail "ssh-keygen failed (exit code $($p.ExitCode))."
    }
    return @{ Dir = $dir; Private = $key; Public = ([System.IO.File]::ReadAllText("$key.pub")).Trim() }
}

# The value part of a KEY=value line, read like lib/common.sh config_value:
# surrounding whitespace, a matching pair of quotes and a " # comment" go.
function ConvertFrom-ConfigValue {
    param([string]$Value)
    $v = $Value.TrimStart()
    $m = [regex]::Match($v, '^"([^"]*)"\s*(#.*)?$')
    if (-not $m.Success) { $m = [regex]::Match($v, "^'([^']*)'\s*(#.*)?$") }
    if ($m.Success) { return $m.Groups[1].Value }
    return ([regex]::Replace($v, '\s#.*$', '')).TrimEnd()
}

# The FLASH_* values of the settings file $Path (only those lines are read).
function Read-FlashConfig {
    param([string]$Path)
    $values = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $m = [regex]::Match($line, '^\s*(export\s+)?(FLASH_[A-Z0-9_]*)=(.*)$')
        if (-not $m.Success) { continue }
        $key = $m.Groups[2].Value
        if ($Script:FlashNames -notcontains $key) { Write-Warn "${Path}: ignoring unknown setting $key"; continue }
        $values[$key] = ConvertFrom-ConfigValue $m.Groups[3].Value
    }
    return $values
}

# Merge parameters, environment and settings file (in that order of priority).
function Get-FlashSettings {
    param([hashtable]$Given, [hashtable]$FromFile)
    $s = @{}
    foreach ($name in $Script:FlashNames) {
        $v = $Given[$name]
        if (-not $v) { $v = [Environment]::GetEnvironmentVariable($name) }
        if (-not $v -and $FromFile) { $v = $FromFile[$name] }
        $s[$name] = [string]$v
    }
    return $s
}

# True when any first-boot setting is requested (the country alone is not one).
function Test-FirstBootWanted {
    param([hashtable]$Settings)
    return [bool]($Settings['FLASH_HOSTNAME'] -or $Settings['FLASH_WIFI_SSID'] -or $Settings['FLASH_SSH_PUBKEY_FILE'] -or
                  $Settings['FLASH_GITHUB_KEY'] -eq 'yes')
}

# The OpenSSH public key lines of $Path; fails unless every non-comment line
# is one key and there is at least one.
function Read-PublicKeys {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "SSH public key file not found: $Path" }
    # .NET resolves relative paths against the process directory, not the
    # PowerShell location, so resolve it first.
    $lines = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path).ProviderPath)
    if (($lines -join "`n") -match '-----BEGIN') { Fail "$Path is a private key. Pass the public key instead (the .pub file)." }
    $keys = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -cnotmatch $Script:FlashKeyPattern -or $line -match '[\x00-\x08\x0A-\x1F\x7F]') {
            Fail "$Path does not look like an SSH public key (expected e.g. 'ssh-ed25519 AAAA... you@pc', as in id_ed25519.pub)."
        }
        $keys += $line
    }
    if ($keys.Count -eq 0) { Fail "$Path contains no SSH public key." }
    return ,$keys
}

# Check the settings before anything is written. Upper-cases the country and
# reads the key file into SSH_KEYS. Never prints the Wi-Fi password.
function Assert-FlashSettings {
    param([hashtable]$Settings)
    $h = $Settings['FLASH_HOSTNAME']
    if ($h -and ($h.Length -gt 63 -or $h -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$')) {
        Fail "Invalid hostname '$h'. Use 1-63 letters, digits and '-', not starting or ending with '-'."
    }
    $cc = $Settings['FLASH_WIFI_COUNTRY']
    if (-not $cc) { $cc = 'DE' }
    $cc = $cc.ToUpperInvariant()
    if ($cc -cnotmatch '^[A-Z]{2}$') { Fail "Invalid Wi-Fi country '$cc'. Use a 2-letter code such as DE, AT, CH, GB or US." }
    $Settings['FLASH_WIFI_COUNTRY'] = $cc
    $ssid = $Settings['FLASH_WIFI_SSID']
    $pass = $Settings['FLASH_WIFI_PASSWORD']
    if ($ssid) {
        if ([System.Text.Encoding]::UTF8.GetByteCount($ssid) -gt 32) { Fail 'Wi-Fi SSID is longer than 32 bytes.' }
        if ($ssid -match '[\x00-\x1F\x7F]') { Fail 'Wi-Fi SSID must not contain control characters.' }
        if ($pass -and $pass -notmatch '^[\x20-\x7E]{8,63}$' -and $pass -notmatch '^[0-9A-Fa-f]{64}$') {
            Fail 'Wi-Fi password must be 8-63 printable ASCII characters (or a 64-digit hex key).'
        }
    } elseif ($pass) {
        Fail 'A Wi-Fi password was given without an SSID. Set the SSID too (-WifiSsid or FLASH_WIFI_SSID).'
    }
    $Settings['SSH_KEYS'] = @()
    if ($Settings['FLASH_SSH_PUBKEY_FILE']) { $Settings['SSH_KEYS'] = Read-PublicKeys $Settings['FLASH_SSH_PUBKEY_FILE'] }
    $gk = ([string]$Settings['FLASH_GITHUB_KEY']).ToLowerInvariant()
    if ($gk -in @('y', 'yes', 'true', '1')) { $gk = 'yes' } elseif ($gk -in @('', 'n', 'no', 'false', '0')) { $gk = 'no' }
    else { Fail "Invalid GitHub key setting '$($Settings['FLASH_GITHUB_KEY'])'. Use yes or no." }
    $Settings['FLASH_GITHUB_KEY'] = $gk
}

# The first SSH public key in $HOME\.ssh, or $null.
function Get-DefaultPublicKey {
    foreach ($name in @('id_ed25519.pub', 'id_ecdsa.pub', 'id_rsa.pub')) {
        $p = Join-Path (Join-Path $HOME '.ssh') $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

# Ask for each first-boot setting that no parameter, environment variable or
# settings file gave. Enter keeps the default in brackets. Without a console to
# ask on (input redirected) nothing is asked.
function Test-CanPrompt { return -not [Console]::IsInputRedirected }

# One answer from the console (a seam the tests replace).
function Read-Answer { param([string]$Prompt) return Read-Host $Prompt }

function Request-FlashSettings {
    param([hashtable]$Settings)
    if (-not (Test-CanPrompt)) { return }
    if (-not $Settings['FLASH_HOSTNAME']) {
        $Settings['FLASH_HOSTNAME'] = (Read-Answer 'Hostname for the Pi [raspberrypi]').Trim()
    }
    if (-not $Settings['FLASH_WIFI_SSID']) {
        $Settings['FLASH_WIFI_SSID'] = Read-Answer 'Wi-Fi network name (empty for a network cable only)'
    }
    if ($Settings['FLASH_WIFI_SSID'] -and -not $Settings['FLASH_WIFI_COUNTRY']) {
        $Settings['FLASH_WIFI_COUNTRY'] = (Read-Answer 'Wi-Fi country code [DE]').Trim()
    }
    if (-not $Settings['FLASH_SSH_PUBKEY_FILE']) {
        $default = Get-DefaultPublicKey
        if ($default) {
            $k = (Read-Answer "Your PC's SSH public key, to log in to the Pi without a password ['none' to skip] [$default]").Trim()
            if (-not $k) { $k = $default } elseif ($k -eq 'none') { $k = '' }
        } else {
            $k = (Read-Answer "Your PC's SSH public key file, to log in to the Pi without a password (empty to skip)").Trim()
        }
        if ($k -match '^~') { $k = $HOME + $k.Substring(1) }
        $Settings['FLASH_SSH_PUBKEY_FILE'] = $k
    }
    # The Pi's own GitHub key is made without asking; -GitHubKey no turns it off.
    if (-not $Settings['FLASH_GITHUB_KEY']) { $Settings['FLASH_GITHUB_KEY'] = 'yes' }
}

# Ask for the Wi-Fi password when an SSID is set without one. An empty answer
# means an open network.
function Request-WifiPassword {
    param([hashtable]$Settings)
    if (-not $Settings['FLASH_WIFI_SSID'] -or $Settings['FLASH_WIFI_PASSWORD']) { return }
    $sec = Read-Host -AsSecureString "Wi-Fi password for '$($Settings['FLASH_WIFI_SSID'])' (hidden, empty for an open network)"
    if ($sec -and $sec.Length -gt 0) {
        $Settings['FLASH_WIFI_PASSWORD'] = [Net.NetworkCredential]::new('', $sec).Password
        Assert-FlashSettings $Settings
    } else {
        Write-Warn "No Wi-Fi password: '$($Settings['FLASH_WIFI_SSID'])' is set up as an open network."
    }
}

# Quote $Value as a YAML single-quoted scalar, where only ' needs escaping.
function ConvertTo-YamlQuoted {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

# Write $Lines to $Path with LF line endings and no BOM, as the Pi expects.
function Write-UnixFile {
    param([string]$Path, [string[]]$Lines)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $enc)
}

# First line of the boot partition's cmdline.txt, or $null if there is none.
function Get-CmdlineText {
    param([string]$Root)
    $path = Join-Path $Root 'cmdline.txt'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return ([System.IO.File]::ReadAllText($path) -split "`r?`n")[0]
}

# Set the Wi-Fi regulatory domain on the kernel command line, replacing an
# earlier one, as Raspberry Pi Imager does.
function Set-CmdlineRegdom {
    param([string]$Root, [string]$Country)
    $line = Get-CmdlineText $Root
    if ($null -eq $line) { Write-Warn 'No cmdline.txt on the boot partition; the Wi-Fi country is only set in the network settings.'; return }
    $line = [regex]::Replace($line, '\s*cfg80211\.ieee80211_regdom=\S*', '')
    Write-UnixFile (Join-Path $Root 'cmdline.txt') @("$line cfg80211.ieee80211_regdom=$Country")
}

# cloud-init user-data (and network-config when Wi-Fi is set) for images
# seeded from the boot partition (Trixie). No users: entry: the login user
# still comes from userconf.txt.
function Write-CloudInit {
    param([string]$Root, [string]$UserName, [hashtable]$Settings)
    $ud = @(
        '#cloud-config',
        '# Written by rpi-setup host/flash.ps1. The login user comes from userconf.txt',
        '# and SSH is enabled by the empty "ssh" file, as without these settings.'
    )
    if ($Settings['FLASH_HOSTNAME']) {
        $ud += "hostname: $(ConvertTo-YamlQuoted $Settings['FLASH_HOSTNAME'])"
        $ud += 'manage_etc_hosts: true'
    }
    $wantKey = $Settings['FLASH_GITHUB_KEY'] -eq 'yes'
    if ($Settings['SSH_KEYS'].Count -gt 0 -or $wantKey) { $ud += 'write_files:' }
    if ($Settings['SSH_KEYS'].Count -gt 0) {
        $ud += "  - path: $Script:FlashSshdConf"
        $ud += "    permissions: '0644'"
        $ud += '    content: |'
        $ud += "      $Script:FlashSshdLine"
        $ud += "  - path: /etc/ssh/authorized_keys/$UserName"
        $ud += "    permissions: '0644'"
        $ud += '    content: |'
        foreach ($k in $Settings['SSH_KEYS']) { $ud += "      $k" }
    }
    if ($wantKey) {
        # Only the script and its unit: the private key itself stays out of
        # user-data, which remains on the boot partition.
        $ud += "  - path: $Script:FlashGitHubKeyScriptPath"
        $ud += "    permissions: '0755'"
        $ud += '    content: |'
        foreach ($l in (Get-GitHubKeyScript $UserName)) { $ud += "      $l" }
        $ud += "  - path: /etc/systemd/system/$Script:FlashGitHubKeyUnit"
        $ud += "    permissions: '0644'"
        $ud += '    content: |'
        foreach ($l in $Script:FlashGitHubKeyUnitLines) { if ($l) { $ud += "      $l" } else { $ud += '' } }
    }
    if ($Settings['FLASH_WIFI_SSID'] -or $wantKey) { $ud += 'runcmd:' }
    if ($Settings['FLASH_WIFI_SSID']) {
        $ud += "  - [sh, -c, $(ConvertTo-YamlQuoted $Script:FlashRfkillUnblock)]"
    }
    if ($wantKey) {
        $ud += '  - [systemctl, daemon-reload]'
        $ud += "  - [systemctl, enable, $Script:FlashGitHubKeyUnit]"
        $ud += "  - [systemctl, start, --no-block, $Script:FlashGitHubKeyUnit]"
    }
    Write-UnixFile (Join-Path $Root 'user-data') $ud

    if (-not $Settings['FLASH_WIFI_SSID']) { return }
    $nc = @(
        '# Written by rpi-setup host/flash.ps1.',
        'network:',
        '  version: 2',
        '  renderer: NetworkManager',
        '  ethernets:',
        '    eth0:',
        '      dhcp4: true',
        '      optional: true',
        '  wifis:',
        '    wlan0:',
        '      dhcp4: true',
        '      optional: true',
        "      regulatory-domain: $(ConvertTo-YamlQuoted $Settings['FLASH_WIFI_COUNTRY'])",
        '      access-points:'
    )
    $ssid = ConvertTo-YamlQuoted $Settings['FLASH_WIFI_SSID']
    if ($Settings['FLASH_WIFI_PASSWORD']) {
        $nc += "        ${ssid}:"
        $nc += "          password: $(ConvertTo-YamlQuoted $Settings['FLASH_WIFI_PASSWORD'])"
    } else {
        $nc += "        ${ssid}: {}"
    }
    Write-UnixFile (Join-Path $Root 'network-config') $nc
}

# One-time firstrun.sh started from cmdline.txt, for images without cloud-init
# (Bookworm); the route Raspberry Pi Imager takes there. It removes itself and
# its cmdline.txt entry, and the Pi reboots once.
function Write-FirstRun {
    param([string]$Root, [string]$UserName, [hashtable]$Settings)
    $line = Get-CmdlineText $Root
    if ($null -eq $line) { Fail 'No cmdline.txt on the boot partition; cannot start firstrun.sh.' }
    $fr = @(
        '#!/bin/bash',
        '# Written by rpi-setup host/flash.ps1: one-time first-boot settings for images',
        '# without cloud-init. Started from cmdline.txt; removes itself when done.',
        'set +e',
        'BOOT=/boot/firmware',
        '[ -f "$BOOT/cmdline.txt" ] || BOOT=/boot'
    )
    if ($Settings['FLASH_HOSTNAME']) {
        $fr += "NEW_HOSTNAME='$($Settings['FLASH_HOSTNAME'])'"
        $fr += @(
            'echo "$NEW_HOSTNAME" >/etc/hostname',
            'if grep -q "^127\.0\.1\.1" /etc/hosts; then',
            '  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts',
            'else',
            '  printf "127.0.1.1\t%s\n" "$NEW_HOSTNAME" >>/etc/hosts',
            'fi'
        )
    }
    if ($Settings['SSH_KEYS'].Count -gt 0) {
        $fr += 'install -d -m 0755 /etc/ssh/sshd_config.d /etc/ssh/authorized_keys'
        $fr += "echo '$Script:FlashSshdLine' >$Script:FlashSshdConf"
        $fr += "cat >/etc/ssh/authorized_keys/$UserName <<'RPI_SETUP_EOF'"
        $fr += $Settings['SSH_KEYS']
        $fr += 'RPI_SETUP_EOF'
        $fr += "chmod 0644 $Script:FlashSshdConf /etc/ssh/authorized_keys/$UserName"
    }
    if ($Settings['FLASH_WIFI_SSID']) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Settings['FLASH_WIFI_SSID'])
        $ssidList = (($bytes | ForEach-Object { [string]$_ }) -join ';') + ';'
        $fr += @(
            'NM=/etc/NetworkManager/system-connections',
            'install -d -m 0700 "$NM"',
            'cat >"$NM/preconfigured.nmconnection" <<''RPI_SETUP_EOF''',
            '[connection]',
            'id=preconfigured',
            "uuid=$([guid]::NewGuid().ToString())",
            'type=wifi',
            'autoconnect=true',
            '',
            '[wifi]',
            'mode=infrastructure',
            "ssid=$ssidList"
        )
        if ($Settings['FLASH_WIFI_PASSWORD']) {
            # GLib key file escaping: backslash and spaces.
            $psk = ($Settings['FLASH_WIFI_PASSWORD'] -replace '\\', '\\') -replace ' ', '\s'
            $fr += @('', '[wifi-security]', 'key-mgmt=wpa-psk', "psk=$psk")
        }
        $fr += @(
            '',
            '[ipv4]',
            'method=auto',
            '',
            '[ipv6]',
            'method=auto',
            'RPI_SETUP_EOF',
            'chmod 0600 "$NM/preconfigured.nmconnection"',
            $Script:FlashRfkillUnblock
        )
    }
    if ($Settings['FLASH_GITHUB_KEY'] -eq 'yes') {
        # Runs on the next boot, after userconf.txt has created the login user.
        $fr += "cat >$Script:FlashGitHubKeyScriptPath <<'RPI_SETUP_EOF'"
        $fr += Get-GitHubKeyScript $UserName
        $fr += 'RPI_SETUP_EOF'
        $fr += "chmod 0755 $Script:FlashGitHubKeyScriptPath"
        $fr += "cat >/etc/systemd/system/$Script:FlashGitHubKeyUnit <<'RPI_SETUP_EOF'"
        $fr += $Script:FlashGitHubKeyUnitLines
        $fr += 'RPI_SETUP_EOF'
        $fr += "systemctl enable $Script:FlashGitHubKeyUnit"
    }
    $fr += @(
        'rm -f "$BOOT/firstrun.sh"',
        'sed -i "s| systemd.run.*||g" "$BOOT/cmdline.txt"',
        'exit 0'
    )
    Write-UnixFile (Join-Path $Root 'firstrun.sh') $fr

    if ($line -notmatch 'systemd\.run=') {
        $line += ' systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target'
    }
    Write-UnixFile (Join-Path $Root 'cmdline.txt') @($line)
}

# Write the requested first-boot settings into the boot partition at $Root.
# Writes nothing when no setting is requested.
function Write-FirstBootSettings {
    param([string]$Root, [string]$UserName, [hashtable]$Settings)
    if (-not (Test-FirstBootWanted $Settings)) { return }
    if ($Settings['FLASH_WIFI_SSID']) { Set-CmdlineRegdom -Root $Root -Country $Settings['FLASH_WIFI_COUNTRY'] }
    if ($Settings['FLASH_GITHUB_KEY'] -eq 'yes') {
        $key = $Settings['GITHUB_KEY']
        $dest = Join-Path $Root $Script:FlashGitHubKeyFile
        Write-UnixFile $dest (([System.IO.File]::ReadAllText($key.Private) -replace "`r", '').TrimEnd("`n") -split "`n")
        Write-UnixFile "$dest.pub" @($key.Public)
    }
    if ((Test-Path -LiteralPath (Join-Path $Root 'user-data')) -or (Test-Path -LiteralPath (Join-Path $Root 'meta-data'))) {
        Write-CloudInit -Root $Root -UserName $UserName -Settings $Settings
        $what = "'user-data'"
        if ($Settings['FLASH_WIFI_SSID']) { $what += " and 'network-config'" }
        Write-Step "Wrote cloud-init settings to $Root : $what"
    } else {
        Write-FirstRun -Root $Root -UserName $UserName -Settings $Settings
        Write-Step "No cloud-init on this image (e.g. Bookworm): wrote 'firstrun.sh'; the Pi reboots once on first boot."
    }
    if ($Settings['FLASH_HOSTNAME']) { Write-Info "Hostname: $($Settings['FLASH_HOSTNAME'])" }
    if ($Settings['FLASH_WIFI_SSID']) { Write-Info "Wi-Fi: '$($Settings['FLASH_WIFI_SSID'])' (country $($Settings['FLASH_WIFI_COUNTRY']))" }
    if ($Settings['SSH_KEYS'].Count -gt 0) { Write-Info "SSH key(s) from $($Settings['FLASH_SSH_PUBKEY_FILE']) authorized for '$UserName'" }
    if ($Settings['FLASH_GITHUB_KEY'] -eq 'yes') { Write-Info "New GitHub SSH key: moves to ~/.ssh/id_ed25519_github of '$UserName' on first boot" }
}

# Print the Pi's new GitHub public key and where to add it.
function Write-GitHubKeyNotice {
    param([string]$PublicKey)
    Write-Host ''
    Write-Step 'New SSH key for the Pi. Add it to GitHub so the Pi can reach your repositories:'
    Write-Host '    https://github.com/settings/ssh/new   (or as a deploy key of one repository)'
    Write-Host ''
    Write-Host "    $PublicKey"
    Write-Host ''
    Write-Info 'Only the card has the private key; it was not kept on this PC.'
}

# --- main -------------------------------------------------------------
# Below the marker, so ci/test-flash.ps1 can load the functions without admin.
#Requires -RunAsAdministrator

try {
    if (-not $DownloadDir) { $DownloadDir = Join-Path $PSScriptRoot 'downloads' }

    # First-boot settings are checked before anything is downloaded or written.
    $configDir = $env:RPI_SETUP_CONFIG_DIR
    if (-not $configDir) { $configDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'config' }
    $given = @{
        FLASH_HOSTNAME        = $Hostname
        FLASH_WIFI_SSID       = $WifiSsid
        FLASH_WIFI_PASSWORD   = $WifiPassword
        FLASH_WIFI_COUNTRY    = $WifiCountry
        FLASH_SSH_PUBKEY_FILE = $SshPublicKeyFile
        FLASH_GITHUB_KEY      = $GitHubKey
    }
    $firstBoot = Get-FlashSettings -Given $given -FromFile (Read-FlashConfig (Join-Path $configDir 'rpi-setup.env'))
    if ($SkipCustomize -and (Test-FirstBootWanted $firstBoot)) {
        Fail '-SkipCustomize cannot be combined with a hostname, Wi-Fi or SSH key setting.'
    }
    if (-not $SkipCustomize) { Request-FlashSettings $firstBoot }
    Assert-FlashSettings $firstBoot
    Request-WifiPassword $firstBoot
    # Ask for (and check) the login user before the card is wiped, so a typo
    # cannot leave a freshly written card without 'ssh' and 'userconf.txt'.
    if (-not $SkipCustomize) {
        $cred = Get-Credentials -UserName $UserName -Password $Password
        $passHash = New-CryptHash $cred.Pass
    }
    if ($firstBoot['FLASH_GITHUB_KEY'] -eq 'yes') {
        $keyHost = $firstBoot['FLASH_HOSTNAME']
        if (-not $keyHost) { $keyHost = 'raspberrypi' }
        $firstBoot['GITHUB_KEY'] = New-GitHubKey -Comment ("{0}@{1}" -f $cred.User, $keyHost)
    }

    # Pick the card last among the questions, so the slow part (Imager,
    # download, write) runs without anyone having to wait at the keyboard.
    $targetDisk = Select-Disk $Disk

    $imager = Find-Imager
    Write-Step "Using Raspberry Pi Imager: $imager"

    if ($Image) {
        if (-not (Test-Path -LiteralPath $Image)) { Fail "Image not found: $Image" }
        Write-Step "Using image: $Image"
        $img = @{ Path = $Image }
    } else {
        $img = Get-Image $DownloadDir
    }

    Invoke-Flash -Disk $targetDisk -ImagePath $img.Path -Imager $imager

    if (-not $SkipCustomize) {
        Add-FirstBootFiles -DiskNumber $targetDisk.Number -UserName $cred.User -PasswordHash $passHash -Settings $firstBoot
    }

    if (-not $NoEject -and (Dismount-Card $targetDisk.Number)) {
        Write-Step 'Done. The SD card is ejected: take it out, insert it into the Pi, and power on.'
    } else {
        Write-Step 'Done. Safely eject the SD card, insert it into the Pi, and power on.'
    }
    if (-not $SkipCustomize) {
        Write-Host ''
        Write-Info 'After the Pi has booted (give it ~1-2 minutes on first boot), connect over SSH:'
        $piHost = $firstBoot['FLASH_HOSTNAME']
        if (-not $piHost) { $piHost = 'raspberrypi' }
        Write-Host ("    ssh {0}@{1}.local" -f $cred.User, $piHost)
        Write-Info 'Then on the Pi:'
        Write-Host '    git clone https://github.com/Chriszly/rpi-setup.git'
        Write-Host '    cd rpi-setup && sudo bash setup.sh'
        if ($firstBoot['GITHUB_KEY']) { Write-GitHubKeyNotice $firstBoot['GITHUB_KEY'].Public }
    }
}
finally {
    # The Pi's GitHub key is never left on this PC, whether the run succeeded or not.
    if ($firstBoot -and $firstBoot['GITHUB_KEY']) {
        Remove-Item -LiteralPath $firstBoot['GITHUB_KEY'].Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Cleanup is never skipped: once the script installed Imager, it is
    # removed on success AND on any failure, and the cached installers are
    # cleared, so the next run starts clean without stale artifacts.
    if ($Script:ImagerInstalledByScript) { Uninstall-Imager }
}
