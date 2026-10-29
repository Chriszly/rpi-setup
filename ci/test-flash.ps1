#!/usr/bin/env pwsh
# test-flash.ps1 - Unit tests for host/flash.ps1 logic that does not need
# admin privileges, a physical SD card, Imager or network access.
#
# Loads flash.ps1's function definitions (skipping main()) and asserts on the
# pure logic: Imager install-path detection, argument quoting, the settings
# file, the credential and disk checks (with made-up disks) and the guard
# that keeps main() from colliding with the [int]$Disk parameter.
#
# Run: pwsh -NoProfile -File ci/test-flash.ps1
# CI runs it with PowerShell 7 and with Windows PowerShell 5.1, which
# flash.ps1 is written for.
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

# --- Functional cases: Fail throws instead of exiting, so a refusal can be asserted.
# The console and disk seams of flash.ps1 are replaced for them and put back after.
$origFail = ${function:Fail}
${function:Fail} = { param([string]$m) throw $m }
$seams = @{}
foreach ($n in @('Read-Secret', 'Confirm-Destroy', 'Get-AllDisks', 'Get-DiskNow')) { $seams[$n] = (Get-Item "function:$n").ScriptBlock }
function Get-FailMessage { param([scriptblock]$Block) try { & $Block | Out-Null; return '' } catch { return $_.Exception.Message } }
try {
    # Expand-HomePath: ~/ and ~\ from a settings file are expanded, other paths kept
    Assert-True (((Expand-HomePath -Path '~/.ssh/id_ed25519.pub' -HomeDir 'C:\Users\alex') -replace '/', '\') -eq 'C:\Users\alex\.ssh\id_ed25519.pub') 'Expand-HomePath expands a leading ~/'
    Assert-True ((Expand-HomePath -Path '~\keys\pi.pub' -HomeDir 'C:\Users\alex') -eq 'C:\Users\alex\keys\pi.pub') 'Expand-HomePath expands a leading ~\'
    Assert-True ((Expand-HomePath -Path 'C:\keys\~\pi.pub' -HomeDir 'C:\Users\alex') -eq 'C:\keys\~\pi.pub') 'Expand-HomePath leaves a ~ elsewhere alone'
    Assert-True ((Expand-HomePath -Path '' -HomeDir 'C:\Users\alex') -eq '') 'Expand-HomePath keeps an empty path empty'
    $keyDir = Join-Path ([IO.Path]::GetTempPath()) ("flash_home_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $keyDir 'keys') | Out-Null
    Set-Content -LiteralPath (Join-Path $keyDir 'keys\pi.pub') -Value 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBx4Wp1PpH0Qm5b6kG5a0bq0nZ4s2yY1j0mQ3v5fYk8e you@pc'
    try {
        $s = @{ FLASH_HOSTNAME = ''; FLASH_WIFI_SSID = ''; FLASH_WIFI_PASSWORD = ''; FLASH_WIFI_COUNTRY = ''; FLASH_SSH_PUBKEY_FILE = (Join-Path $keyDir 'keys\pi.pub'); FLASH_GITHUB_KEY = '' }
        Assert-FlashSettings $s
        Assert-True ($s['SSH_KEYS'].Count -eq 1) 'Assert-FlashSettings reads the key file'
        Assert-True ($source -match "Expand-HomePath \`$Settings\['FLASH_SSH_PUBKEY_FILE'\]") 'Assert-FlashSettings expands ~/ in FLASH_SSH_PUBKEY_FILE (settings file and environment, not only a typed answer)'
    } finally { Remove-Item -LiteralPath $keyDir -Recurse -Force -ErrorAction SilentlyContinue }

    # ConvertTo-GitHubKeySetting: normalised before the -SkipCustomize check in main()
    Assert-True ((ConvertTo-GitHubKeySetting 'true') -eq 'yes' -and (ConvertTo-GitHubKeySetting '1') -eq 'yes' -and (ConvertTo-GitHubKeySetting 'Y') -eq 'yes') 'ConvertTo-GitHubKeySetting turns true, 1 and Y into yes'
    Assert-True ((ConvertTo-GitHubKeySetting 'false') -eq 'no' -and (ConvertTo-GitHubKeySetting '0') -eq 'no') 'ConvertTo-GitHubKeySetting turns false and 0 into no'
    Assert-True ((ConvertTo-GitHubKeySetting '') -eq '') 'ConvertTo-GitHubKeySetting leaves an empty setting empty'
    Assert-True ((Get-FailMessage { ConvertTo-GitHubKeySetting 'maybe' }) -match 'Invalid GitHub key setting') 'ConvertTo-GitHubKeySetting refuses maybe'
    Assert-True ($source -match "(?s)ConvertTo-GitHubKeySetting \`$firstBoot\['FLASH_GITHUB_KEY'\].*if \(\`$SkipCustomize -and \(Test-FirstBootWanted") 'main() normalises FLASH_GITHUB_KEY before the -SkipCustomize check'

    # Read-FlashConfig: the first of a repeated setting wins, with a warning (as flash.sh)
    $cfg = Join-Path ([IO.Path]::GetTempPath()) ("flash_cfg_" + [guid]::NewGuid().ToString('N') + '.env')
    Set-Content -LiteralPath $cfg -Value "FLASH_HOSTNAME=first`nFLASH_WIFI_SSID=`"net`"`nFLASH_HOSTNAME=second`n"
    try {
        $warned = (Read-FlashConfig $cfg 6>&1 | Out-String)
        $v = Read-FlashConfig $cfg 6>$null
        Assert-True ($v['FLASH_HOSTNAME'] -eq 'first') 'Read-FlashConfig keeps the first value of a repeated setting'
        Assert-True ($warned -match 'set more than once') 'Read-FlashConfig warns about a repeated setting'
        Assert-True ($v['FLASH_WIFI_SSID'] -eq 'net') 'Read-FlashConfig unquotes values'
        $merged = Get-FlashSettings -Given @{ FLASH_HOSTNAME = '' } -FromFile $v
        Assert-True ($merged['FLASH_HOSTNAME'] -eq 'first') 'Get-FlashSettings: an empty parameter takes the file value (empty means default)'
    } finally { Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue }

    # Get-Credentials: asked twice, the rules are no ":" and no control characters (like flash.sh)
    $script:secrets = @()
    function Read-Secret { param([string]$Prompt) $a = $script:secrets[0]; $script:secrets = @($script:secrets | Select-Object -Skip 1); $a }
    try {
        $script:secrets = @('longpassword', 'longpassword')
        $c = Get-Credentials -UserName 'pi'
        Assert-True ($c.Pass -eq 'longpassword' -and $script:secrets.Count -eq 0) 'Get-Credentials asks for the password twice and takes a matching pair'
        $script:secrets = @('longpassword', 'longpassw0rd')
        Assert-True ((Get-FailMessage { Get-Credentials -UserName 'pi' }) -match 'do not match') 'Get-Credentials refuses a repeat that differs'
        $script:secrets = @('', '')
        Assert-True ((Get-FailMessage { Get-Credentials -UserName 'pi' }) -match 'Password required') 'Get-Credentials refuses an empty password'
        $umlaut = 'gr' + [char]0xFC + [char]0xDF + 'e aus k' + [char]0xF6 + 'ln'
        $c = Get-Credentials -UserName 'pi' -Password $umlaut
        Assert-True ($c.Pass -ceq $umlaut) 'Get-Credentials accepts umlauts and spaces in the password'
        Assert-True ((Get-FailMessage { Get-Credentials -UserName 'pi' -Password 'a:b' }) -match 'colon') 'Get-Credentials refuses a colon'
        Assert-True ((Get-FailMessage { Get-Credentials -UserName 'pi' -Password "long`tpassword" }) -match 'control characters') 'Get-Credentials refuses a tab'
        Assert-True ((Get-FailMessage { Get-Credentials -UserName 'Pi' -Password 'longpassword' }) -match 'Invalid username') 'Get-Credentials refuses an upper-case user name'
    } finally { Set-Item function:Read-Secret $seams['Read-Secret'] }

    # Select-Disk: the fallback list (no removable disk) is never written unattended
    $script:confirmed = @()
    function Confirm-Destroy { param([object]$Disk) $script:confirmed += $Disk.Number }
    function Get-AllDisks {
        $all = @(
            [pscustomobject]@{ Number = 0; BusType = 'NVMe'; IsSystem = $true;  IsBoot = $true;  Size = 512GB; FriendlyName = 'System SSD';   SerialNumber = 'S0' },
            [pscustomobject]@{ Number = 1; BusType = 'SATA'; IsSystem = $false; IsBoot = $false; Size = 2048GB; FriendlyName = 'Data SSD';    SerialNumber = 'S1' }
        )
        if ($script:withReader) {
            $all += [pscustomobject]@{ Number = 2; BusType = 'USB'; IsSystem = $false; IsBoot = $false; Size = 16GB; FriendlyName = 'Card Reader'; SerialNumber = 'S2' }
        }
        return $all
    }
    function Get-DiskNow { param([int]$Number) return (Get-AllDisks | Where-Object Number -eq $Number) }
    try {
        $script:withReader = $false
        Set-Variable -Name Force -Value $true
        $msg = Get-FailMessage { Select-Disk 1 }
        Assert-True ($msg -match 'not a removable SD/USB/MMC disk' -and $msg -match '-Force') 'Select-Disk -Disk 1 -Force refuses an internal data disk when no removable disk is found'
        Assert-True ($script:confirmed.Count -eq 0) 'Select-Disk did not reach the confirmation for it'
        Set-Variable -Name Force -Value $false
        $d = Select-Disk 1
        Assert-True ($d.Number -eq 1 -and $script:confirmed -contains 1) 'Select-Disk -Disk 1 without -Force offers the internal disk only after the yes confirmation'
        $script:withReader = $true
        Set-Variable -Name Force -Value $true
        $script:confirmed = @()
        $d = Select-Disk 2
        Assert-True ($d.Number -eq 2 -and $script:confirmed.Count -eq 0) 'Select-Disk -Disk 2 -Force writes the card reader unattended'
        Assert-True ((Get-FailMessage { Select-Disk 1 }) -match 'not found among removable disks') 'Select-Disk -Disk 1 -Force refuses the internal disk while a card reader is present'
        Set-Variable -Name Force -Value $false

        # Assert-DiskUnchanged: the disk is compared again right before Imager writes it
        $chosen = Select-Disk 2
        Assert-True ((Get-FailMessage { Assert-DiskUnchanged $chosen }) -eq '') 'Assert-DiskUnchanged passes for the same disk'
        $script:withReader = $false
        Assert-True ((Get-FailMessage { Assert-DiskUnchanged $chosen }) -match 'is gone') 'Assert-DiskUnchanged stops when the disk is gone'
        $script:withReader = $true
        $swapped = [pscustomobject]@{ Number = 2; Size = 32GB; FriendlyName = 'Card Reader'; SerialNumber = 'S2' }
        Assert-True ((Get-FailMessage { Assert-DiskUnchanged $swapped }) -match 'not the disk that was confirmed') 'Assert-DiskUnchanged stops when a different card is in the reader'
        Assert-True ($source -match '(?s)Assert-DiskUnchanged \$targetDisk\s*\n\s*Invoke-Flash') 'main() re-checks the disk right before Invoke-Flash'
    } finally {
        foreach ($n in @('Confirm-Destroy', 'Get-AllDisks', 'Get-DiskNow')) { Set-Item "function:$n" $seams[$n] }
    }

    # Get-FreeDriveLetter: no 'D'..'Z' char range (Windows PowerShell 5.1 has none)
    Assert-True ((Get-FreeDriveLetter -Used @('C', 'D', 'E')) -eq 'F') 'Get-FreeDriveLetter skips the letters in use'
    Assert-True ((Get-FreeDriveLetter -Used @()) -eq 'D') 'Get-FreeDriveLetter starts at D'
    Assert-True ((Get-FreeDriveLetter -Used @([char[]](67..90) | ForEach-Object { [string]$_ })) -eq '') 'Get-FreeDriveLetter returns nothing when all are taken'
    Assert-True ($source -notmatch "'D'\.\.'Z'") "flash.ps1 has no 'D'..'Z' character range"

    # Request-WifiPassword: nothing is asked without a console; a typed password is checked
    function Test-CanPrompt { $false }
    $s = @{ FLASH_WIFI_SSID = 'net'; FLASH_WIFI_PASSWORD = '' }
    $warned = (Request-WifiPassword $s 6>&1 | Out-String)
    Assert-True (-not $s['FLASH_WIFI_PASSWORD'] -and $warned -match 'open network') 'Request-WifiPassword without a console means an open network'
    Remove-Item function:Test-CanPrompt
    Assert-True ($source -match '(?s)function Request-WifiPassword \{.*?Test-CanPrompt.*?\n\}') 'Request-WifiPassword asks only when Test-CanPrompt allows it'
} finally {
    ${function:Fail} = $origFail
}

# --- Installer and download: signature check, progress bar for the image
Assert-True ($source -match '(?s)function Install-Imager \{.*?Assert-ImagerSignature -Path \$installer.*?Start-Process') 'Install-Imager checks the Authenticode signature before running the installer'
Assert-True ($source -match "\`$sig\.Status -ne 'Valid' -or \`$signer -notmatch 'Raspberry Pi'") 'Assert-ImagerSignature needs a valid signature from Raspberry Pi'
Assert-True ($source -match '-OutFile \$imgPath -ProgressBar') 'the image download shows a progress bar'
Assert-True ($source -match '-OutFile \$shaPath\s*\n') 'the checksum download stays silent'

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
Assert-True ([RpiSetupEject]::EjectDevice('USBSTOR\NO&SUCH&DEVICE\0') -like 'device not found*') 'the USB eject reports a missing device instead of throwing'
Assert-True ($source -match '-not \$NoEject -and \(Dismount-Card \$targetDisk\.Number\)') 'main() ejects the card at the end unless -NoEject'

# --- New-CryptHash: the hash is of the password itself, without a CR or LF
$ssl = Find-OpenSsl
if ($ssl) {
    $h = New-CryptHash 'testpass1'
    $salt = $h.Split('$')[2]
    $plain = (& $ssl passwd -6 -salt $salt 'testpass1' | Out-String).Trim()
    Assert-True ($h -ceq $plain) 'New-CryptHash hashes exactly the password (no byte order mark in front)'
    Assert-True ((Invoke-OpenSslPasswd -OpenSsl $ssl -Password 'testpass1' -Salt $salt) -ceq $plain) 'Invoke-OpenSslPasswd with a salt matches openssl passwd'
    # SHA-512 crypt of the UTF-8 bytes of "p<a-umlaut>sswort1" with salt abcdefgh (openssl passwd -6 on Linux).
    $umlautHash = '$6$abcdefgh$K4BI4oPrwPDm8goAfeftcXeqTUNJYO20.lIEi1y3nIX4K8J80z8gKzvVt5fOI3cEvoCMO.HydwvloJOOOOLwV1'
    $umlautPw = 'p' + [char]0xE4 + 'sswort1'
    Assert-True ((Invoke-OpenSslPasswd -OpenSsl $ssl -Password $umlautPw -Salt 'abcdefgh') -ceq $umlautHash) 'Invoke-OpenSslPasswd hashes the UTF-8 bytes of an umlaut password (what the Pi''s login compares)'
} else {
    Write-Host '[SKIP] New-CryptHash needs openssl'
}

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
