# Adobe Lightroom Classic on Linux via Wine — Full Guide

This is the step-by-step recipe for installing and running **Adobe Lightroom
Classic** (the local-catalog desktop photo app — *not* Lightroom CC /
"Lightroom Desktop") on Linux using Wine staging, from Adobe's standalone
offline installer.

It assumes:

- You're comfortable opening a terminal and running `apt`/`dnf`/`pacman`.
- You've installed wine before, even if just `winetricks corefonts`.
- You have a valid Lightroom Classic license and can obtain Adobe's standalone
  offline installer (`Set-up.exe` and its sibling folders — see section 4).
- You can read shell scripts well enough to know whether you trust them before
  running.

It does **not** assume you know anything about DXVK, D2D, vkd3d-proton, or the
Adobe binary stack — those are explained as we go.

Tested combination:

| Component       | Version / detail                                   |
|-----------------|----------------------------------------------------|
| Host OS         | Arch Linux, GNOME (Wayland session)                |
| Wine            | 11.10 (Staging) — also tested on 11.9              |
| Winetricks      | recent (20240105+)                                 |
| DXVK            | 2.7.1 (installed via winetricks)                   |
| Wine Gecko      | 2.47.4 (both x86 and x86_64)                        |
| vkd3d-proton    | 3.0.0 (real D3D12)                                 |
| GPU             | Intel Iris Xe, Vulkan working                      |

DXVK and vkd3d-proton are vendor-agnostic, so NVIDIA and AMD GPUs should work
too — we tested on Intel Iris Xe.

---

## 0. The easy way: `./start.sh`

If you just want it working, **run the menu** and follow the recommended steps —
you do not have to call the individual scripts by hand:

```bash
./start.sh                 # interactive menu
./start.sh --verbose       # same, but show each step's wine err: output
```

It detects how far your setup has got (prefix? GPU? CC installed? Classic
installed? fixes applied?) and marks the recommended next action with an arrow.
Every menu entry just runs one of the `scripts/` below — nothing is hidden — so
this guide's per-script detail still applies; the menu only saves you typing and
running them in the right order.

```
  1) Prepare wine prefix (setup)                    → resources/scripts/wine/setup.sh            (§3)
  2) Install GPU acceleration (vkd3d-proton)        → resources/scripts/wine/install-vkd3d-proton.sh (§7)
  --- install Lightroom Classic — pick ONE route ---
  3) via Creative Cloud — online installer  (recommended, bundles CoreSync)
                                                    → resources/scripts/creative-cloud/install-creative-cloud-live.sh (§5)
  4) via Creative Cloud — offline ACCCx.zip         → resources/scripts/creative-cloud/install-creative-cloud.sh (§5)
  5) via standalone Set-up.exe                      → resources/scripts/lightroom/install-lightroom-classic.sh (§5)
  6) Post-install fixes                             → resources/scripts/lightroom/install-lightroom-classic-fixes.sh (§6)
  --- run ---
  7) Run Lightroom Classic                          → resources/scripts/lightroom/run-lightroom-classic.sh (§8)
  8) Run Creative Cloud app                         → resources/scripts/creative-cloud/run-creative-cloud.sh
  g) Add to application menu                        → resources/scripts/lightroom/install-desktop-entry.sh (§8)
  --- other ---
  9) Set Windows version (win7/win10/win11)         → resources/scripts/wine/set-winver.sh
  k) Kill the wine session (wineserver -k)          → if an app hangs/won't relaunch
  r) Reset / wipe the prefix                        → resources/scripts/wine/reset-wineprefix.sh
```

**When something goes wrong, try `k` first.** Adobe's background services
(Adobe Desktop Service, AdobeIPCBroker, CoreSync, the Creative Cloud helpers)
keep running after an app closes or crashes, and a fresh launch then just hands
off to them — so the app hangs, shows no window, or won't relaunch. Option `k`
runs `WINEPREFIX="$PWD/wineprefix" wineserver -k`, which kills every wine process
in the prefix. It only stops *running* processes — your install, settings, and
the DXVK shader cache on disk are untouched. After it, relaunch the app (7 or 8).
It's the safe "turn it off and on again" before the destructive `r` (reset).

**Typical first run:** `1` → `2` → `5` (standalone, simplest for just Classic) →
`6` → `7`. If you specifically want the **Creative Cloud desktop app** (Apps
panel, updates, other apps), use `3` instead of `5` — see §5's CC notes for why
the *online* installer (`3`) is the one that works and the offline `ACCCx.zip`
(`4`) leaves the panels blank.

The rest of this guide explains what each of those scripts does and why, so you
can run them directly, debug them, or understand the fixes. Read on for the
detail.

---

## 1. Prereqs

Install the packages your distro needs. Pick the section that matches:

### Ubuntu / Pop!_OS / Debian

```bash
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install -y \
  curl wget unzip git xz-utils ca-certificates \
  build-essential pkg-config \
  mingw-w64 \
  winbind cabextract \
  mesa-vulkan-drivers libvulkan1 vulkan-tools
```

### Fedora

```bash
sudo dnf install -y \
  curl wget unzip git xz \
  @development-tools \
  mingw64-gcc mingw32-gcc \
  samba-winbind cabextract \
  mesa-vulkan-drivers vulkan-tools
```

### Arch / Manjaro

```bash
sudo pacman -S --needed \
  curl wget unzip git \
  base-devel \
  mingw-w64-gcc \
  samba cabextract \
  vulkan-icd-loader vulkan-tools
```

You also need `winetricks` ≥ 20240105 — your distro's package usually has it,
but if not, fetch the latest:

```bash
curl -L https://raw.githubusercontent.com/Winetricks/winetricks/master/resources/winetricks \
  -o ~/.local/bin/winetricks
chmod +x ~/.local/bin/winetricks
```

For GPU acceleration (section 7) you'll also need a source of **vkd3d-proton**:
either `winetricks vkd3d`, or a Proton / GE-Proton runner that bundles it. More
in section 7.

---

## 2. Install Wine Staging

Follow WineHQ's per-distro instructions: <https://wiki.winehq.org/Download>

You want `winehq-staging` (Ubuntu/Debian) or `wine-staging` (Fedora/Arch),
version **11.8 or newer** (we run 11.10; also tested on 11.9).

Verify:

```bash
wine --version
# expected: wine-11.10 (Staging)   (or higher)
```

If you have a system `wine` already and want this install isolated, WineHQ also
publishes a portable tarball you can extract to e.g. `/opt/wine-staging/` and
reference by absolute path. The rest of this guide just says `wine`; substitute
as needed (the scripts honor `WINE=/path/to/wine`).

---

## 3. Set up the wine prefix

A wine *prefix* is a self-contained C: drive plus registry. We keep ours under
the repo (`wineprefix/`) separate from `~/.wine` so breaking it can't break
other wine apps.

Clone this repo, then run the setup script:

```bash
git clone https://github.com/sander110419/lightroom-cc-on-linux.git
cd lightroom-cc-on-linux
./resources/scripts/wine/setup.sh
```

`resources/scripts/wine/setup.sh` does the following, idempotently (re-running skips
already-done steps):

1. Creates `wineprefix/` (`WINEARCH=win64`), boots it, sets the Windows version
   to 10.
2. Installs winetricks verbs: `corefonts ucrtbase2019 vcrun2019 msxml6 gdiplus
   dotnet48 atmlib fontsmooth=rgb dxvk`.
3. Downloads Wine Gecko 2.47.4 (x86_64 + x86 MSIs), installs both, and repairs
   the `MSHTML\2.47.4\GeckoPath` registry value to match where the MSI actually
   put the files.
4. Writes `wineprefix/dxvk.conf` with
   `dxgi.enableDummyCompositionSwapchain = True` (the Adobe installer engine's
   Electron/WebView2 UI calls `CreateSwapChainForComposition`, which DXVK
   otherwise stubs).
5. Applies `wineprefix/adobe-fixes.reg` — NLA "active probing" registry keys so
   Adobe reports itself online instead of falling back to a broken offline code
   path.
6. Builds the `hnetcfg` stub (via `resources/scripts/stubs/build-stubs.sh`), installs it as
   `system32/hnetcfg.dll`, and registers its DllOverride (`native,builtin`).
7. Installs the patched `d2d1.dll` and `mfplat.dll` (if present in
   `resources/stubs/binaries/`) into `system32/` and sets their DllOverrides to `native`.

It takes ~30 minutes the first time, mostly waiting on `dotnet48` and font
downloads. The script is short and commented — read it if you'd rather do steps
by hand.

### The `hnetcfg` stub (section 6 detail)

| Stub          | Why                                                                 |
|---------------|---------------------------------------------------------------------|
| `hnetcfg.dll` | Lightroom Classic does an in-process COM load of `hnetcfg.dll` (firewall config). Wine 11.x ships no loadable `hnetcfg`, so the load fails with `c0000135` and `ole:apartment_add_dll` errors. The stub returns an empty firewall-rules enumerator so the probe succeeds cleanly. |

Source is in `resources/stubs/sources/hnetcfg.c`; `resources/scripts/stubs/build-stubs.sh` compiles it
with mingw-w64 (`x86_64-w64-mingw32-gcc`) to `hnetcfg-stub.dll`. `setup.sh`
runs the build and installs it as `system32/hnetcfg.dll`.

> **Note — removed CC-era stubs.** This project began as a Lightroom *CC* port,
> which shipped stubs for `NDFAPI.DLL`, `wkscli.dll`,
> `ext-ms-win-uiacore-l1-1-2.dll`, `thumbcache.dll` and `adobe_e26b366d.dll`.
> A full `WINEDEBUG=+loaddll` trace of Classic (launch → Library → import →
> Develop) showed **none of them are ever loaded by Classic** — they targeted
> CC's Electron/desktop-app code paths. They were removed; `hnetcfg` is the only
> stub Classic actually needs.

### The patched `d2d1.dll`

When Lightroom opens its main window it asks Direct2D for a rendering context
that supports the `CLSID_D2D1ColorManagement` builtin effect
(`{1a28524c-fdd6-4aa4-ae8f-837eb8267b37}`). Wine ships only a subset of D2D's
builtin effects and `ColorManagement` isn't one — LR's startup probe then fails
with `CreateD2DDeviceResources failed. HResult: 0x88990028`. The patched
`d2d1.dll` registers `ColorManagement` as a passthrough no-op effect, which is
all LR needs (it never actually invokes the effect at edit time). The override
(`d2d1=native`) forces wine to load the patched copy.

### The patched `mfplat.dll`

Adobe media code paths delay-load `MFCreateSampleCopierMFT` from `mfplat.dll`,
but wine puts that symbol in `mf.dll`, not `mfplat.dll`. The patched
`mfplat.dll` is wine's `mfplat.dll` with one added **forwarder export**
(`MFCreateSampleCopierMFT → mf.MFCreateSampleCopierMFT`) so the delay-load
resolves cleanly. `resources/scripts/stubs/patch_mfplat.py` performs this binary patch on any
baseline `mfplat.dll` (reads the PE, appends a new export directory with all
originals plus the forwarder, rewrites `DataDirectory[0]`, zeroes the
wine-builtin signature so the override takes as native):

```bash
# Requires python3 + pefile (pip install pefile)
resources/scripts/stubs/patch_mfplat.py /path/to/source/mfplat.dll /path/to/output/mfplat.dll
```

> **Classic vs CC note:** unlike Lightroom CC, Classic does **not** ship its own
> bundled `mfplat.dll` inside its install directory, so there's no
> "replace the Adobe-bundled copy" step. The patched `d2d1.dll`/`mfplat.dll` in
> `system32/` (from `setup.sh`) cover Classic.

---

## 4. Obtain the standalone Lightroom Classic installer

Adobe gates this behind a login, so we can't do it for you. You need Adobe's
**standalone offline** Lightroom Classic installer — a directory containing
`Set-up.exe` (sometimes `setup.exe`) plus sibling folders like `products/`,
`resources/`, `packages/`. Keep those siblings next to `Set-up.exe`; the Adobe
HD installer needs them.

Place the installer here (the default the script looks for):

```bash
mkdir -p resources/installers/lightroom
# copy the whole installer folder so Set-up.exe ends up at:
#   resources/installers/lightroom/Set-up.exe
# with products/ resources/ packages/ alongside it
```

You can also keep it anywhere and pass the path as an argument to the install
script (section 5).

---

## 5. Install Lightroom Classic

```bash
./resources/scripts/lightroom/install-lightroom-classic.sh
# or with an explicit installer path:
./resources/scripts/lightroom/install-lightroom-classic.sh /path/to/Set-up.exe
```

What the script does, and **why** each fix is needed:

1. **Verifies** the prefix exists and locates `Set-up.exe`.
2. **Forces the prefix to report Windows 11** (`winetricks -q win11`, build
   22000). The standalone Adobe HD installer runs its *own* OS-version check
   that the CC desktop app skips. A fresh prefix can report Win7 (build 7601),
   which the installer rejects with *"you are running an incompatible os
   version"* → *"System Requirements check failed."* Win11 clears it. (You can
   read the installer's own check in `HDInstaller.log`, decoded as UTF-16LE.)
3. **Ensures Microsoft Edge WebView2 is installed** (the Adobe installer engine
   needs it; the script downloads and silently installs it if missing).
4. **Launches the installer with `winegstreamer` disabled**
   (`WINEDLLOVERRIDES="winegstreamer="`). The installer's embedded Gecko/xul UI
   tries to init audio on startup: `l3codecx.ax` → `winegstreamer` →
   `mfplat.MFCreateAudioMediaType`, which wine 11.x stubs. The stub aborts the
   call and kills the whole installer mid-run. Disabling `winegstreamer` skips
   the media path entirely; the installer UI doesn't need audio.

Sign in / accept the prompts in the installer UI and wait for it to finish.
Classic installs to:

```
wineprefix/drive_c/Program Files/Adobe/Adobe Lightroom Classic/
```

with the main executable `Lightroom.exe`.

### Alternative: install via the Creative Cloud desktop app

If you want Adobe's Creative Cloud desktop app itself (to install Classic from
its Apps panel, manage updates, or run other CC apps), there are **two** CC
routes — and which one you pick decides whether the app's panels actually work.

#### Recommended: the ONLINE installer (`install-creative-cloud-live.sh`, menu 3)

Download the small online bootstrapper **`Creative_Cloud_Set-Up.exe`** from
<https://creativecloud.adobe.com/apps/download/creative-cloud>, drop it in
`resources/installers/`, then:

```bash
./resources/scripts/creative-cloud/install-creative-cloud-live.sh
```

It installs WebView2, then runs the bootstrapper in two phases (sign in, then a
clean wine-session restart to pass the OS check) and downloads the **current**
CC desktop app. The current build ships **CoreSync** (which provides
`CoreSync.exe` and `CCXProcess.exe`, the processes that render the Home / Apps /
Files / Fonts panels), so the panels work. After install it disables every
`AdobeGrowthSDK.dll` / `growthsdk.node` copy (they call the wine-unimplemented
`kernel32.SetThreadpoolTimerEx` and abort the Experience `node.exe`).

#### Back-version: the OFFLINE `ACCCx*.zip` (`install-creative-cloud.sh`, menu 4)

The offline `ACCCx*.zip` from the same page is a **back-version**. It installs
the CC core but then wants a self-update before it will install CoreSync — and
under wine that self-update sits behind a "click Update Now" bar that needs a
panel applet to render, which needs CoreSync: a catch-22. Symptom: the CC window
opens but the **panels never load** ("waiting" forever); `ACC.log` repeats
`OnProcessPingMiss`, `Could not get CCXP endpoint`, and
`Unable to launch CoreSync Process. No version of core sync is installed.`. Use
this route only if you already have the zip and don't need the panels.

#### Either route, then:

Launch the app with `./resources/scripts/creative-cloud/run-creative-cloud.sh` (menu 8). Sign in with
your Adobe ID — note the login WebView2's cursor is invisible under wine, but it
works blind: click the email field, type, **Tab**, type password, **Enter**.
Then click **Install** on **Lightroom Classic** in the Apps panel. Classic lands
in the same `Program Files/Adobe/Adobe Lightroom Classic/` directory, so the
rest of this guide (sections 6–8) applies unchanged.

Notes:

- `run-creative-cloud.sh` launches CC's CEF with `--disable-gpu
  --disable-gpu-compositing` (the CC desktop UI has no use for the GPU, and the
  GPU path crashes the CEF process on a cold DXVK cache). **Never** add
  `--in-process-gpu` — it deadlocks the UI under wine. Always launch CC through
  this script so the flags are applied; a bare `wine "...Creative Cloud.exe"`
  will crash with an access violation.
- `setup.sh` disables the dead `ir50_32`/`iyuv_32` codecs (§3 / §0) because
  loading them tips wine into TLS-slot exhaustion that deadlocks CC at startup
  (panels paint but never finish loading). If you built your prefix before this
  was added, see the troubleshooting entry on `SetThreadpoolTimerEx` /
  `alloc_tls_slot`.
- Unlike the standalone installer, the CC desktop app skips its own OS-version
  check. If an in-CC app install fails with an "incompatible os version" error,
  run `winetricks -q win11` against the prefix and retry.

---

## 6. Post-install fixes

```bash
./resources/scripts/lightroom/install-lightroom-classic-fixes.sh
```

These can only run *after* Classic is on disk. The script:

1. **Disables Classic's bundled `AdobeGrowthSDK.dll`** (renames it to
   `.disabled`). That DLL calls `kernel32.SetThreadpoolTimerEx`, which wine 11.x
   does not implement, so loading it aborts the process. Classic has a fallback
   path that works fine without it.
2. **Creates lowercase symlinks** for every `*.dll`/`*.exe` in the Classic
   install dir. Classic's import tables list some DLLs in lowercase while Adobe
   ships the files in MixedCase. On real Windows the PE loader is
   case-insensitive; wine on Linux is case-sensitive on disk, so the imports
   fail with `module:import_dll ... not found` unless both names exist.

That's all the post-install steps; the `hnetcfg` stub and the patched
`d2d1`/`mfplat` from `setup.sh` already cover Classic (section 3).

---

## 7. GPU acceleration (vkd3d-proton)

```bash
./resources/scripts/wine/install-vkd3d-proton.sh
```

**Why:** wine's *builtin* `d3d12.dll` reports a fake placeholder adapter
("Intel HD Graphics 4000"), with no real D3D12 backing. Lightroom Classic's
CameraRaw GPU manager enumerates that, finds no usable D3D12 device, reports
`GPU system count: 0` / `GPU Init Status: I1_Failed`, and the GPU dropdown in
**Preferences > Performance** stays greyed out. Develop runs CPU-only.

**The fix:** install **vkd3d-proton**'s *real* D3D12 (`d3d12.dll` +
`d3d12core.dll`) into the prefix and set both to `native`. vkd3d-proton is
Vulkan-backed (like DXVK) and runs fine on system wine + system Vulkan — **no
Proton-wine swap is needed**. After this, CameraRaw fully enumerates and
qualifies the real GPU (verified: a D3D12 device on Intel Iris Xe, vendor
`0x8086` device `0x46a6`, FL 12.1, vkd3d-proton 3.0.0), the Performance GPU
dropdown works, and Develop is fluid.

The script backs up wine's builtin `d3d12*.dll` (`*.wine-builtin-bak`) before
overwriting, then sets the `native` overrides. It sources vkd3d-proton in this
order:

1. `$VKD3D_SRC` if you set it to a directory containing `d3d12.dll` +
   `d3d12core.dll`.
2. A GE-Proton runner under Bottles, if found
   (`…/files/lib/wine/vkd3d-proton/x86_64-windows/`).
3. Otherwise `winetricks -q vkd3d` (downloads official vkd3d-proton).

### Optional Intel→AMD spoof (OFF by default)

The script has an opt-in adapter spoof, gated behind `LR_GPU_SPOOF=1`:

```bash
LR_GPU_SPOOF=1 ./resources/scripts/wine/install-vkd3d-proton.sh
```

It appends `dxgi.customVendorId/DeviceId/DeviceDesc` ("AMD Radeon RX 6800 XT")
to `dxvk.conf`. Lightroom routes AI Masking inference to CPU when it sees an
Intel GPU (`Masking AI inference running on CPU: Intel parts`), and that CPU
path fails under wine; spoofing the adapter as AMD flips LR onto the
GPU/DirectML path. **It is off by default for two reasons:** (a) AI Masking
*still* fails afterwards because Adobe's models are encrypted and the
decrypt-load step is the real wall (not the GPU — see KNOWN_ISSUES), and (b) the
AMD render path **blanks the Develop/Library histogram** entirely under DXVK.
For normal use, leave it off: real-Intel + GPU-on gives correct photo colors and
a (monochrome) histogram.

---

## 8. Run Lightroom Classic

```bash
./resources/scripts/lightroom/run-lightroom-classic.sh
```

Expected: the Library module loads with your catalog. Click into **Develop** to
edit; sliders and manual masks apply in real time.

The launcher is self-contained and configurable via env vars:

- **`LR_DPI`** (default `144`) — HiDPI UI scaling, written to the prefix's
  `HKCU\Control Panel\Desktop\LogPixels`. `96`=100%, `120`=125%, `144`=150%,
  `192`=200%. Set `LR_DPI=96` to disable scaling.
- **`LR_DRIVER`** (`auto`|`x11`|`wayland`, default `auto`→`x11`) — graphics
  driver. `x11` (through Xwayland on Wayland sessions) is the compatible
  default. `wayland` uses native `winewayland.drv` (which would pass
  EDID/HDR/colorimetry through) but is **experimental**: on GNOME/Mutter +
  wine 11.9 it can fail to start the explorer/window driver and crash LrC. Only
  use it if it works for you.
- **Log suppression** — the launcher silences known-cosmetic channels by
  default: `combase` (WinRT `RoGetActivationFactory` "Failed to find library"),
  `ole` (Adobe-internal CLSIDs not registered), and several UI "unknown msg"
  channels via `WINEDEBUG`; plus `DXVK_LOG_LEVEL=none` and `VKD3D_DEBUG=none`
  for the DXVK/vkd3d device-info dumps and the harmless EDID/colorimetry lines.
  Override any of these by exporting your own value.

### Add it to your application menu

To launch Lightroom from your desktop's application menu (any environment —
KDE, LXDE, XFCE, GNOME, …) instead of the terminal, use menu option **`g`**
(*Add to application menu*) in `./start.sh`. It asks for the UI scale (DPI) and
whether to use a virtual desktop, then installs a freedesktop `.desktop`
launcher that runs through `run-lightroom-classic.sh` (so every fix applies).

Or run the script directly:

```bash
./resources/scripts/lightroom/install-desktop-entry.sh --dpi=144   # optional: --vdesktop, --remove
```

It writes `~/.local/share/applications/adobe-lightroom-classic.desktop`,
harvests Lightroom's icons into the hicolor theme under a stable name, and
removes wine's own auto-generated entry — that one calls `Lightroom.exe`
**raw** (bypassing all our fixes) and hard-codes the prefix path it saw at
install time, so it silently breaks if the repo ever moves.

> wine's `winemenubuilder` may recreate its broken entry after a later wine
> run; just re-run option `g` (or the script) to clean it up.

---

## 9. Troubleshooting

### `wine client error:0: version mismatch` / nothing launches after a wine update

```
wine client error:0: version mismatch 935/943.
Your wineserver binary was not upgraded correctly, ...
```

You upgraded wine while a `wineserver` from the **old** version was still
running in this prefix. The old server keeps its old protocol number, so the
new wine client refuses to attach — and every launch route (the application-menu
launcher, the CLI, `start.sh` runs) dies instantly. Kill the stale server:

```bash
WINEPREFIX=$PWD/wineprefix wineserver -k     # or: start.sh option k
```

Then relaunch. (Tested across a 11.9 → 11.10 upgrade.)

### Installer aborts immediately / "System Requirements check failed"

The prefix is reporting an OS version below Win10. The install script forces
Win11, but if you ran the installer by hand, set it first:

```bash
WINEPREFIX=$PWD/wineprefix winetricks -q win11
```

(Inspect `HDInstaller.log` — UTF-16LE — to confirm the OS check is what failed.)

### Installer window opens then dies mid-run

`winegstreamer` aborted on `mfplat.MFCreateAudioMediaType`. Launch the installer
with it disabled (the script does this for you):

```bash
WINEDLLOVERRIDES="winegstreamer=" wine /path/to/Set-up.exe
```

### `wine: Unimplemented function KERNEL32.dll.SetThreadpoolTimerEx`

An `AdobeGrowthSDK.dll` (or `growthsdk.node`) is still active. Run the
post-install fixes script, or disable every copy by hand — the Creative Cloud
online installer drops them in both `Program Files` and `Program Files (x86)`:

```bash
find wineprefix \( -iname 'AdobeGrowthSDK.dll' -o -iname 'growthsdk.node' \) \
  ! -name '*.disabled'
# rename each result to .disabled
```

### Creative Cloud window opens but panels never load / `alloc_tls_slot NtQueryInformationThread failed`

The CC desktop app's panels are blank and `ACC.log` shows endless
`OnProcessPingMiss` / `Could not get CCXP endpoint`. Two distinct causes:

1. **CoreSync not installed** (`Unable to launch CoreSync Process. No version of
   core sync is installed.`) — you used the offline `ACCCx.zip`. Reinstall with
   the **online** installer (`install-creative-cloud-live.sh`, menu 3); it
   bundles CoreSync. See §5.
2. **TLS-slot exhaustion → startup deadlock** (`err:module:alloc_tls_slot
   NtQueryInformationThread failed`, then `err:sync:RtlpWaitForCriticalSection
   ... blocked by <tid>, retrying (60 sec)`) — the dead `ir50_32`/`iyuv_32`
   codecs are loading and eating TLS slots. `setup.sh` now disables them; on an
   older prefix, do it by hand and relaunch:

   ```bash
   cd "wineprefix/drive_c/windows/system32"
   mv ir50_32.dll ir50_32.dll.disabled
   mv iyuv_32.dll iyuv_32.dll.disabled
   ```

### `module:import_dll ... not found` listing an Adobe DLL

Case sensitivity. Re-run the lowercase-symlink step (the fixes script), or the
loop by hand inside the Classic install dir:

```bash
cd "wineprefix/drive_c/Program Files/Adobe/Adobe Lightroom Classic"
for f in *.dll *.exe; do
  lower=$(echo "$f" | tr '[:upper:]' '[:lower:]')
  [ "$f" != "$lower" ] && [ ! -e "$lower" ] && ln -s "$f" "$lower"
done
```

### LR starts, but "CreateD2DDeviceResources failed. HResult: 0x88990028"

The patched `d2d1.dll` isn't installed or its override isn't set. Re-run
`setup.sh`, or verify:

```bash
wine reg QUERY "HKCU\Software\Wine\DllOverrides" /v d2d1
# expected: d2d1   REG_SZ   native
```

### Preferences > Performance shows no GPU / dropdown greyed out

wine's fake builtin d3d12 is still in place. Run
`./resources/scripts/wine/install-vkd3d-proton.sh` to drop in vkd3d-proton's real D3D12, then
relaunch.

### After a failed Wayland (`LR_DRIVER=wayland`) attempt, LrC won't relaunch

A crashed Wayland attempt can leave a stale wineserver in mixed driver state
(symptoms include a `KERNEL32.dll.UnregisterApplicationRecoveryCallback` abort).
Kill it before relaunching on X11:

```bash
WINEPREFIX=$PWD/wineprefix wineserver -k
```

### Import OR Masking crashes with `BadMatch ... X_CopyArea` (opcode 62)

```
X Error of failed request:  BadMatch (invalid parameter attributes)
  Major opcode of failed request:  62 (X_CopyArea)
```

On a Wayland session (Xwayland), wine's X11 driver issues a `CopyArea` between
drawables of mismatched depth/visual and Xwayland rejects it, aborting
Lightroom. Two *different* modules hit this two *different* ways — both are
fixed automatically by the launcher + the post-install fixes script:

**Develop > Masking** — triggered by Adobe's dunamis in-app "feedback"/tip
(`dunamis_feedback_show` right before the abort). `install-lightroom-classic-fixes.sh`
empties and locks read-only the dunamis feedback dir
(`…/AppData/Roaming/com.adobe.dunamis/feedback`) so the tip never renders.
`dunamis-ingest.dll` itself can't be removed — `Lightroom.exe` hard-imports it
(`c0000135`) — so we deny it the feedback content instead. Re-run the fixes
script if Masking starts crashing again.

**Import** — wine copies the import thumbnail grid via a **MIT-SHM** (shared
memory) pixmap whose depth/visual doesn't match the destination window.

**Default fix (automatic):** `run-lightroom-classic.sh` exports
`WINE_X11_NO_MITSHM=1`, which makes wine use plain matched copies instead of
shared-memory pixmaps. Import then works with normal rootless windows (so GNOME
still HiDPI-scales the UI). Override with `WINE_X11_NO_MITSHM=0`. Launching by
hand? Just prefix it:

```bash
WINE_X11_NO_MITSHM=1 wine "C:\\Program Files\\Adobe\\Adobe Lightroom Classic\\Lightroom.exe"
```

**Fallback:** if MIT-SHM-off isn't enough on your setup, run inside a wine
virtual desktop — `run-lightroom-classic.sh --vdesktop` (or menu option **8**),
or by hand:

```bash
wine explorer /desktop=lrc,WIDTHxHEIGHT \
  "C:\\Program Files\\Adobe\\Adobe Lightroom Classic\\Lightroom.exe"
```

The virtual desktop is one root window wine owns (no cross-depth copy to the X
server), but it doesn't get GNOME's per-window HiDPI scaling, so the UI can look
tiny — raise `LR_DPI` (e.g. `LR_DPI=240`) to compensate.

Note: this is an X11/graphics-layer abort, not a missing-DLL error — no stub DLL
(`thumbcache`, `NDFAPI`, etc.) affects it.

### AI Masking / object/subject/background detect / AI Denoise does nothing

This is a known hard limitation, not a misconfiguration. See
[`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) #1 — Adobe's ML models are encrypted and the
failure is inside Adobe's proprietary decrypt-then-load step.

### Histogram is grey/monochrome with GPU on

Known DXVK 2.7.1 limitation (KNOWN_ISSUES #2). Photo colors are correct. Turn
GPU off in Preferences > Performance for a full-color histogram at the cost of
edit speed.

### Want to debug the ML-masking failure yourself

`resources/scripts/lightroom/debug-lightroom-classic-ml.sh` launches LrC with vkd3d/shader warnings
on, logging to `/tmp/lrc-ml-debug.log`. Trigger detection, quit, then run the
`grep` it prints. (We've already chased this to Adobe's encrypted-model wall;
see KNOWN_ISSUES #1.)
