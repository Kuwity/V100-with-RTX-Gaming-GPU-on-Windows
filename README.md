# V100 + RTX 3080 on Windows

Running a **NVIDIA Tesla V100-SXM2 16 GB** and a **GeForce RTX 3080 12 GB** simultaneously
on **Windows 11** — without Linux, without test mode (for the most part).

NVIDIA does not ship a single Windows driver that supports both a Data Center (TCC) V100
and a GeForce card. This repo documents the three problems I hit and the working solution:

1. **PCIe slot / bandwidth** — hardware placement
2. **Driver compatibility** — INF modification of the Data Center driver
3. **Dual-GPU coexistence** — a `pnputil` parent-device reset

Everything below was tested on:

| Component | Value |
|-----------|-------|
| CPU | Intel i5-14400F (6C/12T) |
| RAM | 32 GB DDR4-3200 |
| GPU 0 | Tesla V100-SXM2 16 GB (TCC mode) |
| GPU 1 | GeForce RTX 3080 12 GB (WDDM, display) |
| OS | Windows 11 |
| Driver | 581.42 (Data Center, modified) |
| CUDA | 13.0 |

`nvidia-smi` output after a successful setup:

```
+-----------------------------------------------------------------------------------------+
|   0  Tesla V100-SXM2-16GB         TCC   |   00000000:01:00.0 Off |                    0 |
|   1  NVIDIA GeForce RTX 3080      WDDM  |   00000000:06:00.0  On |                    N/A |
+-----------------------------------------------------------------------------------------+
```

---

## Table of contents

- [Problem 1 — PCIe slot placement](#problem-1--pcie-slot-placement)
- [Problem 2 — No single driver for V100 + GeForce](#problem-2--no-single-driver-for-v100--geforce)
  - [The INF modification (manual)](#the-inf-modification-manual)
  - [The INF modification (automated)](#the-inf-modification-automated)
- [Problem 3 — Dual-GPU coexistence (pnputil reset)](#problem-3--dual-gpu-coexistence-pnputil-reset)
- [Putting it all together — recommended order](#putting-it-all-together--recommended-order)
- [What this does NOT do](#what-this-does-not-do)
- [On another PC](#on-another-pc)
- [Scripts](#scripts)
- [Credits & attribution](#credits--attribution)

---

## Problem 1 — PCIe slot placement

The V100-SXM2 requires **at least PCIe 3.0 x8**. In my board layout that meant:

- **V100 → primary motherboard PCIe slot** (the one wired directly to the CPU at full x16/x8).
- **RTX 3080 → secondary PCIe 4.0 x4 slot** (chipset-fed).

The RTX 3080 lost roughly **10–15 % of its peak power** in the x4 slot. For my use case
(display + inference offloading) that was acceptable; a V100 in the x4 slot would have been
far more punishing.

Check your actual negotiated link width with GPU-Z (basic tab → PCIe) or:

```powershell
Get-CimInstance Win32_PciDevice |
  Where-Object { $_.VendorId -eq '0x10DE' } |
  Select-Object Name, DeviceID, @{n='LinkWidth';e={(Get-CimInstance -Query "SELECT * FROM MSAcpi_ThermalZoneTemperature" -Namespace 'root/wmi')} } 
# Easier: just open GPU-Z and look at "Bus Interface"
```

**BIOS settings worth checking:**

- **Above 4G Decoding** — must be **Enabled** (V100 16 GB BARs exceed 4 GB).
- **Resizable BAR / Smart Access Memory** — usually fine to leave off for a V100.
- Slot power limits — make sure the primary slot is set to x16 or x8 (not "Auto" that
  downclocks when the second slot is populated, on some boards).

---

## Problem 2 — No single driver for V100 + GeForce

NVIDIA's driver split on Windows:

- **Game Ready / Studio drivers** → GeForce only. No V100.
- **Data Center drivers** → Tesla/Quadro/A-series. GeForce is *not* in the INF.

I could not find any stock driver version that lists both. The options:

| Option | Pros | Cons |
|--------|------|------|
| Linux (CUDA) | Native dual support | No Windows desktop |
| Windows test mode | Both work, easy | **No anti-cheat games**, no Windows Update |
| **INF modification** | Both work, normal Windows | Driver is "unsigned", re-do after driver update |

### The INF modification (manual)

> ⚠️ **Do NOT edit the INF in `C:\Windows\System32\DriverStore` directly.**
> Copy the package to a working folder first.

#### Steps

1. **Install** the NVIDIA Data Center driver (e.g. 581.42) normally. The V100 will work;
   the RTX 3080 will show up as a generic / unknown display device.

2. **Locate the driver package:**
   ```powershell
   Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" -Directory -Filter 'nv_disp*'
   ```

3. **Copy** the entire package folder to a working directory:
   ```powershell
   $src = "$env:SystemRoot\System32\DriverStore\FileRepository\nv_dispwi.inf_amd64_XXXXXXXX"
   $dst = "$env:USERPROFILE\Desktop\gpu-driver-mod"
   Copy-Item $src $dst -Recurse
   ```

4. **Open** `nv_dispwi.inf` (inside the copy) in a text editor.

5. **Find the device table** — the section under `[NVIDIA_Devices.NTamd64...]`.
   Look for an **A6000** entry (same GA102 chip as the RTX 3080):
   ```
   %NVIDIA_DEV.2230.1459.10DE% = Section065, PCI\VEN_10DE&DEV_2230&SUBSYS_145910DE
   ```
   Note the **section** (`Section065`) and the **DEV id** (`2230`).

6. **Add your RTX 3080** (DEV id `220A` for the 12 GB model) right below it:
   ```
   %NVIDIA_DEV.220A% = Section065, PCI\VEN_10DE&DEV_220A
   ```
   > **Critical:** it must point to the **same section** as the A6000.
   > That section contains the register/feature flags for the GA102 chip.
   > Pointing it at a Turing or Ampere-data-center section will misconfigure the card.

7. **Add a friendly name** in the `[Strings]` section:
   ```
   NVIDIA_DEV.220A = "NVIDIA GeForce RTX 3080 12GB"
   ```

8. **Install the modified INF** via Device Manager:
   - Device Manager → the unknown NVIDIA display adapter → **Update driver**
   - **Browse my computer for driver software** → **Let me pick from a list**
   - **Have Disk…** → point to the folder containing your edited `nv_dispwi.inf`
   - Accept the "this driver is unsigned" warning

9. **Reboot.** Verify with `nvidia-smi` — both GPUs should appear.

#### RTX 3080 / 3090 / A6000 DEV ids (GA102 family)

| Card | DEV id |
|------|--------|
| RTX 3080 12 GB | `220A` |
| RTX 3080 10 GB | `2208` |
| RTX 3090 | `2204` |
| RTX A6000 | `2230` |
| RTX A5000 | `2231` |

The RTX 40-series (AD10x) needs a different driver branch entirely — this trick only works
when the Data Center INF already contains a pro card on the **same chip**.

### The INF modification (automated)

`Add-GpuToDcInf.ps1` (in [scripts/](scripts/)) automates steps 2–7:

```powershell
# Dry run — show what it would do, change nothing
.\Add-GpuToDcInf.ps1 -DryRun

# For real — auto-detects the card, the package, and the nearest template
.\Add-GpuToDcInf.ps1

# Pin the template (A6000) and set a name
.\Add-GpuToDcInf.ps1 -Name "NVIDIA GeForce RTX 3080 12GB" -TemplateDev 2230
```

It will:
- Find the NVIDIA display device that has **no** `nvlddmkm` service
- Locate the Data Center package in DriverStore
- Pick the nearest-DEV-id entry as a template (override with `-TemplateDev`)
- Copy the package, insert the device line + `[Strings]` entry
- Print the exact lines it added so you can verify before installing

See [scripts/Add-GpuToDcInf.ps1](scripts/Add-GpuToDcInf.ps1) for full parameter docs.

---

## Problem 3 — Dual-GPU coexistence (pnputil reset)

Even with the modified driver, **both cards would not run simultaneously** — one of them
would drop out, show a Code 10, or simply not be visible to `nvidia-smi`.

What fixed it: **removing the V100 and its entire parent PCIe device subtree**, then
re-enumerating.

```powershell
# 1. Find the V100's instance ID
Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -like '*V100*' } |
  Select-Object InstanceId, Status, Class

# 2. Remove it AND its parent bridge (the "PCI\VEN_..." parent)
#    Find the parent:
$pnp = Get-PnpDevice -FriendlyName '*V100*' -ErrorAction SilentlyContinue
$parent = (Get-PnpDeviceProperty -InstanceId $pnp[0].InstanceId -KeyName DEVPKEY_Device_Parent -EA SilentlyContinue).Data
Write-Host "Parent bridge: $parent"

# 3. Disable → remove the V100, then the parent bridge
pnputil /disable-devices "$($pnp[0].InstanceId)"
pnputil /remove-devices "$($pnp[0].InstanceId)"
pnputil /remove-devices "$parent"

# 4. Rescan
pnputil /scan-devices
# (or reboot)
```

The exact `pnputil` flags vary slightly by Windows version; the key idea is:

> **Remove the V100 instance + its parent PCIe bridge, then let Windows re-enumerate them.**

This forces a clean PCI config-space read and re-binds the driver. After this, both cards
were stable across reboots.

---

## Putting it all together — recommended order

1. **BIOS:** Enable Above 4G Decoding. Set primary slot to x16/x8.
2. **Hardware:** V100 in primary slot, RTX 3080 in secondary.
3. **Install** the NVIDIA Data Center driver (V100 works, 3080 is unknown).
4. **Run** `Add-GpuToDcInf.ps1` → install the modified INF via Have Disk.
5. **pnputil reset** the V100 + parent bridge (Problem 3).
6. **Reboot.** Verify: `nvidia-smi` shows both, `GPU-Z` shows correct link widths.
7. **Stress test:** run a CUDA benchmark (e.g. `nvidia-smi -lgc` + a compute task on both
   GPUs) for 10+ minutes to confirm stability.

---

## What this does NOT do

- **No anti-cheat compatibility guarantee.** The modified INF is unsigned. Some
  kernel-level anti-cheats (EAC, Vanguard, etc.) may refuse to run. Test mode has the
  same limitation. If you need anti-cheat games, use a stock GeForce driver and accept
  that the V100 won't be visible to CUDA apps (or use a second Windows/Linux partition).
- **No driver updates.** A Windows Update or NVIDIA driver refresh will overwrite your
  INF modification. Re-run the script after any driver change.
- **No new-arch cards.** This only works when the Data Center INF already contains a
  pro card on the same silicon family. A GeForce on a chip the DC driver doesn't know
  can't be added this way.

---

## On another PC

The script should work on any **Windows 10/11 x64** machine where:

- An NVIDIA **Data Center** driver is already installed.
- The Data Center INF contains a **same-chip pro card** (e.g. A6000 for GA102).
- You have **admin** rights.

If multiple NVIDIA display packages are installed, pass `-SourcePath` to pick the right one.

---

## Scripts

| Script | Purpose |
|--------|---------|
| [`Add-GpuToDcInf.ps1`](scripts/Add-GpuToDcInf.ps1) | Add a GeForce card to the Data Center driver INF |
| [`Reset-PciDevice.ps1`](scripts/Reset-PciDevice.ps1) | Remove + rescan a PCI device and its parent bridge |

---

## Credits & attribution

- INF-modification approach inspired by a script shared via Claude (Anthropic).
- The `pnputil` parent-subtree reset technique was discovered empirically on this system.
- NVIDIA driver INF structure references: NVIDIA's public driver documentation.
- GPU-Z (TechPowerUp) for link-width and chip verification.
