# Adobe Lightroom Classic on Linux via Wine

**Status:** Working as of 2026-05-29 — install, launch, the Develop module,
manual edits, and GPU acceleration all work. AI Masking does not (see
[`KNOWN_ISSUES.md`](KNOWN_ISSUES.md)).

![Screenshot](https://github.com/6im0n/lightroom-classic-on-linux/blob/main/resources/ScreenShot/ScreenShot_9.png)

This repo installs and runs **Adobe Lightroom Classic** (the local-catalog
desktop photo app — NOT Lightroom CC / "Lightroom Desktop") on Linux with Wine.
Run **`./start.sh`** for a guided menu, or call the `scripts/` by hand. You can
install Classic from Adobe's standalone offline `Set-up.exe`, or get the full
**Creative Cloud desktop app** (Apps panel + updates) and install Classic from
there.

> **Thanks to [sander110419](https://github.com/sander110419)** — for the
> original idea on **Lightroom-cc-on-linux** and the patched DLLs (`mfplat`, `d2d1`, `hnetcfg`). That work is
> what this project built on to get Lightroom Classic running on Linux.

## Tested environment

| Component       | Version / detail                                   |
|-----------------|----------------------------------------------------|
| Host OS         | Arch Linux, GNOME (Wayland session)                |
| Wine            | 11.10 (Staging) — also tested on 11.9              |
| DXVK            | 2.7.1                                              |
| vkd3d-proton    | 3.0.0 (real D3D12)                                 |
| GPU             | Intel Iris Xe, Vulkan working                      |
| Graphics driver | X11 / Xwayland (default; Wayland-native is opt-in) |

DXVK and vkd3d-proton are vendor-agnostic, so NVIDIA and AMD GPUs should work
too — we tested on Intel Iris Xe.

## What works

- Installing Lightroom Classic — either from the standalone `Set-up.exe` or via
  the Adobe Creative Cloud desktop app.
- Launching into the Library module.
- The **Develop** module and all manual edits (sliders, tone, color, masks you
  paint by hand, crop, etc).
- **GPU acceleration** (Prefs > Performance detects the GPU once vkd3d-proton's
  real D3D12 is installed).

## What doesn't work

See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md). Short version:

- **AI Masking** (object / subject / background detection, AI Denoise) — Adobe's
  on-device ML models are encrypted; the failure is inside Adobe's proprietary
  decrypt-then-load step, not a wine gap. We declined to reverse-engineer it.
- **Color histogram is monochrome** when GPU acceleration is on (a DXVK 2.7.1
  limitation; photo colors are correct). Turn GPU off for a full-color
  histogram at the cost of speed.
- **HDR** is not available (needs native Wayland + compositor HDR, which crashes
  LrC on this GNOME / wine combo).

## Prereqs

- 64-bit Linux, recent kernel
- Wine 11.8 staging or newer (`wine --version` → `wine-11.9 (Staging)` or similar)
- `winetricks` (recent), `mingw-w64` (to build the stub DLLs), Vulkan drivers
  + `vulkan-tools`
- A source of vkd3d-proton (`winetricks vkd3d`, or a Proton / GE-Proton runner)
- A valid Lightroom Classic license and Adobe's standalone offline installer
  (`Set-up.exe` + its sibling `products/`, `resources/`, `packages/` folders).
  Adobe gates the download behind a login; you provide it.
- ~10 GB free disk for the prefix + install

## Quick start

Install the [prereqs](#prereqs) above, then just run the menu:

```bash
git clone https://github.com/sander110419/lightroom-cc-on-linux.git
cd lightroom-cc-on-linux
./start.sh
```

`./start.sh` is an interactive hub: it detects how far you've got and marks the
**recommended next step** with an arrow. Each entry just runs one of the
`scripts/` for you, in the right order. Follow the arrow:

```
  1) Prepare wine prefix (setup)              ← start here
  2) Install GPU acceleration (vkd3d-proton)
  Install Lightroom Classic — pick ONE route:
  3) via Creative Cloud — online installer    (recommended; full CC app + panels)
  4) via Creative Cloud — offline ACCCx.zip    (back-version; panels stay blank)
  5) via standalone Set-up.exe                 (simplest if you only want Classic)
  6) Post-install fixes
  7) Run Lightroom Classic
  8) Run Creative Cloud app
  g) Add to application menu  (desktop launcher; asks DPI + virtual desktop)
  k) Kill the wine session    (if an app hangs or won't relaunch)
```

> **Stuck?** If an app hangs, shows no window, or won't relaunch, pick **`k`**
> (`wineserver -k`) — it kills the leftover Adobe background processes without
> touching your install. The safe "off and on again" before resetting.

**Just want Lightroom Classic?** Do `1 → 2 → 5 → 6 → 7`. For step 5, drop Adobe's
standalone installer at `resources/installers/lightroom/Set-up.exe` (with its sibling
`products/ resources/ packages/` folders) first.

**Want the Creative Cloud desktop app too** (Apps panel, updates)? Use route `3`
— the **online** installer (`Creative_Cloud_Set-Up.exe`, dropped in
`resources/installers/`). The offline `ACCCx.zip` (route 4) is a back-version whose panels
never load under wine; see [`GUIDE.md`](GUIDE.md) §5.

Prefer to run the steps by hand, or want to know what each does and why? Every
script is documented in [`GUIDE.md`](GUIDE.md) — the menu is just a convenience
wrapper around them. The launchers honor `LR_DPI` (HiDPI, default 144) and
`LR_DRIVER` (`auto`/`x11`/`wayland`, default x11).

## How it works

See [`GUIDE.md`](GUIDE.md) for the full walkthrough — every fix explained and
why it's needed. The non-obvious pieces:

1. **Patched `d2d1.dll`** registering `CLSID_D2D1ColorManagement` (wine doesn't
   ship that builtin effect; LR's startup probe needs it). (sander110419)
2. **Patched `mfplat.dll`** with a `MFCreateSampleCopierMFT` forwarder. (sander110419)
3. **A tiny `hnetcfg.dll` stub** returning an empty firewall-rules enumerator,
   so Classic's in-process COM load of `hnetcfg` (firewall config) succeeds
   instead of failing with `c0000135`. (sander110419)
4. **Windows 11 OS version** — the standalone Adobe installer rejects anything
   below Win10.
5. **`winegstreamer` disabled during install** so the installer UI doesn't abort
   on the stubbed `mfplat.MFCreateAudioMediaType`.
6. **vkd3d-proton's real D3D12** to replace wine's fake placeholder adapter, so
   the GPU is enumerated and qualified.
7. **Lowercase symlinks** for Adobe-bundled DLLs (wine's PE loader is
   case-sensitive on disk).
