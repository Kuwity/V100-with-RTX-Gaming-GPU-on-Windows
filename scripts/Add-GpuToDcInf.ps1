#Requires -Version 5.1
<#
.SYNOPSIS
  Adds an unsupported GeForce card to an installed NVIDIA Data Center driver package.

.DESCRIPTION
  NVIDIA's Windows Data Center driver INF does not list GeForce cards.
  This script copies the installed driver package, finds a same-chip pro-card
  template (e.g. A6000 for a GA102 RTX 3080), and inserts the missing device
  entry + [Strings] name so you can install it via "Have Disk" in Device Manager.

  It does NOT install the driver — it only prepares the modified package.
  You must install it via Device Manager → Update driver → Have Disk.

.PARAMETER DeviceId
  Full PnP instance ID of the card, e.g. 'PCI\VEN_10DE&DEV_220A&...'.
  Auto-detected if omitted (looks for an NVIDIA display device without nvlddmkm).

.PARAMETER Name
  Friendly name to show in Device Manager, e.g. "NVIDIA GeForce RTX 3080 12GB".
  Defaults to the PnP FriendlyName if available.

.PARAMETER TemplateDev
  4-hex DEV id of a same-chip card already in the INF (e.g. 2230 for A6000).
  Auto-picks the nearest-DEV-id entry if omitted.

.PARAMETER SourcePath
  Driver package folder in DriverStore. Auto-found if omitted.
  Pass this when multiple nv_disp* packages exist.

.PARAMETER WorkRoot
  Where to create the modified package copy. Default: Desktop\gpu-driver-mod.

.PARAMETER Install
  Try pnputil /add-driver /install after editing. May be refused because the
  edited INF no longer matches the signed catalog. If refused, use the
  "Have Disk" route in Device Manager instead.

.PARAMETER DryRun
  Show the planned edit and exit without changing anything.

.EXAMPLE
  .\Add-GpuToDcInf.ps1 -DryRun
  Preview what would be done.

.EXAMPLE
  .\Add-GpuToDcInf.ps1 -Name "NVIDIA GeForce RTX 3080 12GB"
  Auto-detect card and package, pin the name.

.EXAMPLE
  .\Add-GpuToDcInf.ps1 -TemplateDev 2230 -Install
  Force A6000 template, attempt pnputil install.

.NOTES
  - Requires Administrator.
  - Windows 10/11 x64, PowerShell 5.1+.
  - The script never modifies files inside C:\Windows — it works on a copy.
#>
[CmdletBinding()]
param(
    [string]$DeviceId,
    [string]$Name,
    [string]$TemplateDev,
    [string]$SourcePath,
    [string]$WorkRoot = "$env:USERPROFILE\Desktop\gpu-driver-mod",
    [switch]$Install,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

# ---------- 0. admin check ----------
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "Run as administrator." -ForegroundColor Red
    exit 1
}
$sys32 = if ([Environment]::Is64BitProcess -or -not [Environment]::Is64BitOperatingSystem) {
    "$env:SystemRoot\System32"
} else {
    "$env:SystemRoot\Sysnative"
}

# ---------- 1. find the card ----------
if (-not $DeviceId) {
    $c = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -like 'PCI\VEN_10DE*' -and
            ((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_Service -ErrorAction SilentlyContinue).Data -ne 'nvlddmkm')
        })
    if ($c.Count -eq 0) {
        Write-Host "No NVIDIA display device without an NVIDIA driver found." -ForegroundColor Yellow
        Write-Host "Pass -DeviceId explicitly, or make sure the card is in Device Manager." -ForegroundColor Yellow
        exit 1
    }
    if ($c.Count -gt 1) {
        $c | Format-Table FriendlyName, Status, InstanceId -Auto | Out-String | Write-Host
        Write-Host "Multiple candidates. Pass -DeviceId." -ForegroundColor Red
        exit 1
    }
    $DeviceId = $c[0].InstanceId
    if (-not $Name -and $c[0].FriendlyName -and $c[0].FriendlyName -notlike '*Basic*') {
        $Name = $c[0].FriendlyName
    }
}
if ($DeviceId -notmatch 'VEN_10DE&DEV_([0-9A-F]{4})') {
    Write-Host "Not a recognised NVIDIA device ID: $DeviceId" -ForegroundColor Red
    exit 1
}
$dev = $Matches[1].ToUpper()
if (-not $Name) { $Name = "NVIDIA GPU (DEV_$dev)" }
Write-Host ""
Write-Host "Card  : DEV_$dev" -ForegroundColor Cyan
Write-Host "Name  : $Name" -ForegroundColor Cyan
Write-Host "ID    : $DeviceId" -ForegroundColor Cyan

# ---------- 2. find the Data Center package ----------
if (-not $SourcePath) {
    $repo = Join-Path $sys32 'DriverStore\FileRepository'
    $pk = @(Get-ChildItem $repo -Directory -Filter 'nv_disp*' -ErrorAction SilentlyContinue)
    if ($pk.Count -eq 0) {
        Write-Host "No NVIDIA display driver package found in DriverStore." -ForegroundColor Red
        exit 1
    }
    if ($pk.Count -gt 1) {
        $pk | ForEach-Object { Write-Host "  $($_.FullName)" }
        Write-Host "Found $($pk.Count) packages. Pass -SourcePath for the Data Center one." -ForegroundColor Red
        exit 1
    }
    $SourcePath = $pk[0].FullName
}
$srcInf = Get-ChildItem $SourcePath -Filter 'nv_disp*.inf' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $srcInf) {
    Write-Host "No nv_disp*.inf under $SourcePath" -ForegroundColor Red
    exit 1
}
Write-Host "Package: $SourcePath" -ForegroundColor Cyan
Write-Host "INF    : $($srcInf.FullName)" -ForegroundColor Cyan

# ---------- 3. read INF, find template ----------
$sr = New-Object IO.StreamReader($srcInf.FullName, [Text.Encoding]::Default, $true)
$text = $sr.ReadToEnd()
$enc = $sr.CurrentEncoding
$sr.Close()
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }

# Match all device table entries:  %NAME% = SectionXXX, PCI\VEN_10DE&DEV_AAAA[&SUBSYS_...]
$rx = '(?im)^[ \t]*%[^%\r\n]+%[ \t]*=[ \t]*([A-Za-z0-9_.]+)[ \t]*,[ \t]*PCI\\VEN_10DE&DEV_([0-9A-F]{4})\b[^\r\n]*'
$all = [regex]::Matches($text, $rx)

# already present?
if ($all | Where-Object { $_.Groups[2].Value -ieq $dev }) {
    Write-Host "DEV_$dev is already in this INF. Nothing to add." -ForegroundColor Yellow
    exit 0
}

# pick template
$tpl = $null
if ($TemplateDev) {
    $tpl = $all | Where-Object { $_.Groups[2].Value -ieq $TemplateDev.ToUpper() } | Select-Object -First 1
}
if (-not $tpl) {
    $tpl = $all | Sort-Object { [math]::Abs([Convert]::ToInt32($_.Groups[2].Value,16) - [Convert]::ToInt32($dev,16)) } |
        Select-Object -First 1
}
if (-not $tpl) {
    Write-Host "No template entry found in the INF." -ForegroundColor Red
    exit 1
}

$section = $tpl.Groups[1].Value
$newDevLine = "%NVIDIA_DEV.$dev% = $section, PCI\VEN_10DE&DEV_$dev"
$newStrLine = "NVIDIA_DEV.$dev = `"$Name`""

# find [Strings] section
$sm = [regex]::Match($text, '(?im)^\[Strings\][^\r\n]*')
if (-not $sm.Success) {
    Write-Host "No [Strings] section in the INF." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Template : $($tpl.Value.Trim())" -ForegroundColor Cyan
Write-Host "  section: $section" -ForegroundColor Cyan
Write-Host "Will add : $newDevLine" -ForegroundColor Green
Write-Host "Will add : $newStrLine   (under [Strings])" -ForegroundColor Green
Write-Host ""
Write-Host "CHECK: the template must be the SAME CHIP family as your card." -ForegroundColor Yellow
Write-Host "  GA102 (RTX 3080/3090/A6000)  →  A6000 (2230)" -ForegroundColor Yellow
Write-Host "  GA100 (RTX 3080 Ti/A5000)    →  A5000 (2231)" -ForegroundColor Yellow
Write-Host "  AD102 (RTX 4080/4090)        →  L4/L40 (check your INF)" -ForegroundColor Yellow
Write-Host ""

if ($DryRun) {
    Write-Host "Dry run: nothing changed." -ForegroundColor Green
    exit 0
}

# ---------- 4. copy package + edit ----------
$stamp = Get-Date -Format yyyyMMdd_HHmmss
$dest = Join-Path $WorkRoot "pkg_$stamp"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item "$($srcInf.DirectoryName)\*" $dest -Recurse -Force
$inf = Join-Path $dest $srcInf.Name

# Insert [Strings] line first (later in file → index of template line stays valid)
$text = $text.Insert($sm.Index + $sm.Length, $nl + $newStrLine)
# Insert device table line right after the template entry
$text = $text.Insert($tpl.Index + $tpl.Length, $nl + $newDevLine)
[IO.File]::WriteAllText($inf, $text, $enc)
Write-Host "Modified INF: $inf" -ForegroundColor Green
Write-Host "Package folder: $dest" -ForegroundColor Green
Write-Host ""

# ---------- 5. install (optional) ----------
if ($Install) {
    Write-Host "Attempting pnputil /add-driver /install ..." -ForegroundColor Cyan
    & "$sys32\pnputil.exe" /add-driver $inf /install
    $code = $LASTEXITCODE
    Write-Host "pnputil exit code: $code" -ForegroundColor $(if($code -eq 0){"Green"}else{"Yellow"})
    if ($code -ne 0) {
        Write-Host ""
        Write-Host "pnputil refused (expected — the INF is now unsigned)." -ForegroundColor Yellow
        Write-Host "Use Device Manager → Update driver → Have Disk → point to: $dest" -ForegroundColor Cyan
    }
} else {
    Write-Host "Install via Device Manager:" -ForegroundColor Cyan
    Write-Host "  1. Open Device Manager" -ForegroundColor Cyan
    Write-Host "  2. Right-click the unknown NVIDIA device → Update driver" -ForegroundColor Cyan
    Write-Host "  3. Browse my computer → Let me pick from a list" -ForegroundColor Cyan
    Write-Host "  4. Have Disk… → browse to: $dest" -ForegroundColor Cyan
    Write-Host "  5. Select the .inf and accept the unsigned-driver warning" -ForegroundColor Cyan
    Write-Host "  6. Reboot" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Opening folder..." -ForegroundColor Yellow
    Start-Process explorer.exe $dest
}

Write-Host ""
Write-Host "After reboot, verify with: nvidia-smi" -ForegroundColor Green
