#Requires -Version 5.1
<#
.SYNOPSIS
  Removes a PCI device (and optionally its parent bridge) from Windows, then rescans.

.DESCRIPTION
  On some systems a V100 + GeForce pair won't coexist until the V100's PCI
  subtree is removed and re-enumerated. This script automates that:

    1. Finds the target device (by friendly name or instance ID).
    2. Resolves its parent PCIe bridge.
    3. Disables → removes the device, then the parent bridge.
    4. Triggers a PCI rescan (pnputil /scan-devices).

  A reboot is still recommended afterward.

.PARAMETER FriendlyName
  Partial friendly name to match, e.g. "V100" or "Tesla V100".

.PARAMETER InstanceId
  Exact PnP instance ID. Skips the friendly-name search.

.PARAMETER IncludeParent
  Also remove the parent PCIe bridge (default: yes for this use case).

.PARAMETER NoRescan
  Skip the pnputil /scan-devices step (useful if you plan to reboot immediately).

.EXAMPLE
  .\Reset-PciDevice.ps1 -FriendlyName "V100"
  Remove the V100 + its parent bridge, then rescan.

.EXAMPLE
  .\Reset-PciDevice.ps1 -InstanceId "PCI\VEN_10DE&DEV_1B38&..."
  Use an exact instance ID.

.EXAMPLE
  .\Reset-PciDevice.ps1 -FriendlyName "V100" -NoRescan
  Remove without rescan (reboot next).

.NOTES
  - Requires Administrator.
  - Windows 10/11.
  - This is a blunt tool: removing the parent bridge may also detach other
    devices on the same PCIe switch. Only use it on a dedicated slot.
#>
[CmdletBinding()]
param(
    [string]$FriendlyName,
    [string]$InstanceId,
    [switch]$IncludeParent = $true,
    [switch]$NoRescan
)
$ErrorActionPreference = 'Stop'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "Run as administrator." -ForegroundColor Red
    exit 1
}

# ---------- 1. find the device ----------
$target = $null
if ($InstanceId) {
    $target = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
    if (-not $target) {
        Write-Host "Instance not found: $InstanceId" -ForegroundColor Red
        exit 1
    }
}
elseif ($FriendlyName) {
    $c = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like "*$FriendlyName*" })
    if ($c.Count -eq 0) {
        Write-Host "No device matching '*$FriendlyName*' found." -ForegroundColor Red
        exit 1
    }
    if ($c.Count -gt 1) {
        $c | Format-Table FriendlyName, InstanceId, Status -Auto | Out-String | Write-Host
        Write-Host "Multiple matches. Pass -InstanceId." -ForegroundColor Red
        exit 1
    }
    $target = $c[0]
}
else {
    Write-Host "Specify -FriendlyName or -InstanceId." -ForegroundColor Red
    exit 1
}

Write-Host "Target : $($target.FriendlyName)" -ForegroundColor Cyan
Write-Host "ID     : $($target.InstanceId)" -ForegroundColor Cyan
Write-Host "Status : $($target.Status)" -ForegroundColor Cyan

# ---------- 2. resolve parent bridge ----------
$parentId = $null
if ($IncludeParent) {
    $parentProp = Get-PnpDeviceProperty -InstanceId $target.InstanceId `
        -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue
    if ($parentProp -and $parentProp.Data) {
        $parentId = $parentProp.Data
        $parentDev = Get-PnpDevice -InstanceId $parentId -ErrorAction SilentlyContinue
        Write-Host "Parent : $($parentDev.FriendlyName)  ($parentId)" -ForegroundColor Cyan
    }
    else {
        Write-Host "Could not resolve parent bridge. Proceeding without it." -ForegroundColor Yellow
    }
}

# ---------- 3. disable + remove ----------
Write-Host ""
Write-Host "Disabling device..." -ForegroundColor Yellow
pnputil /disable-devices "$($target.InstanceId)" 2>&1 | ForEach-Object { Write-Host "  $_" }
Start-Sleep -Milliseconds 500

Write-Host "Removing device..." -ForegroundColor Yellow
pnputil /remove-devices "$($target.InstanceId)" 2>&1 | ForEach-Object { Write-Host "  $_" }

if ($parentId) {
    Write-Host "Removing parent bridge..." -ForegroundColor Yellow
    pnputil /remove-devices "$parentId" 2>&1 | ForEach-Object { Write-Host "  $_" }
}

# ---------- 4. rescan ----------
if (-not $NoRescan) {
    Write-Host ""
    Write-Host "Rescanning for hardware changes..." -ForegroundColor Yellow
    pnputil /scan-devices 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ""
Write-Host "Done. A reboot is recommended." -ForegroundColor Green
Write-Host "After reboot, verify with: nvidia-smi" -ForegroundColor Green
