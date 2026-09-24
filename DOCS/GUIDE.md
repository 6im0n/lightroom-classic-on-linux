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
| Wine            | 11.12 (Staging) — also tested on 11.9, 11.10       |
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
  --- wine installation ---
   1) Prepare wine prefix (setup)                   → resources/scripts/wine/setup.sh            (§3)
   2) Install GPU acceleration (vkd3d-proton)       → resources/scripts/wine/install-vkd3d-proton.sh (§7)
  --- install Lightroom Classic — pick ONE route ---
   3) via Creative Cloud — online installer  (recommended, bundles CoreSync)
                                                    → resources/scripts/creative-cloud/install-creative-cloud-live.sh (§5)
   4) via Creative Cloud — offline ACCCx.zip        → resources/scripts/creative-cloud/install-creative-cloud.sh (§5)
   5) via standalone Set-up.exe                     → resources/scripts/lightroom/install-lightroom-classic.sh (§5)
   6) Post-install fixes                            → resources/scripts/lightroom/install-lightroom-classic-fixes.sh (§6)
   a) Enable AI masking                             → resources/scripts/lightroom/install-ai-masking.sh (§6b)
  --- run ---
   7) Run Lightroom Classic                         → resources/scripts/lightroom/run-lightroom-classic.sh (§8)
   8) Run Lightroom Classic — virtual desktop       → same, with --vdesktop (§9, Import fallback)
   9) Run Creative Cloud app                        → resources/scripts/creative-cloud/run-creative-cloud.sh
   d) Lightroom UI scale (DPI)                      → sets --dpi= for entries 7 and 8 (§8)
   w) Graphics driver (auto / wayland / x11)        → saved in the prefix, used by 7, 8 and the launcher (§8)
   g) Add to application menu                       → resources/scripts/lightroom/install-desktop-entry.sh (§8)
  --- other ---
  10) Set Windows version (win7/win10/win11)        → resources/scripts/wine/set-winver.sh
   b) Rebuild the histogram-fix d2d1.dll            → resources/scripts/wine/build-d2d1-lightroom.sh (§3)
   k) Kill the wine session (wineserver -k)         → if an app hangs/won't relaunch
   r) Reset / wipe the prefix                       → resources/scripts/wine/reset-wineprefix.sh
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
`6` → `a` (AI masking, optional) → `7`. If you specifically want the **Creative Cloud desktop app** (Apps
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

`cabextract` is required: winetricks uses it for the fonts, and `setup.sh` stops
right away with a clear message if it or `winetricks` is missing.

The compilers are optional. Every helper binary ships prebuilt in
`resources/stubs/binaries/`, and the scripts use those unless a source file was
edited after its binary was built. Keep `mingw-w64` (Windows-side stubs:
`hnetcfg`, the dialog-repaint proxy, the WinRT stream DLL) and native `gcc`
(the Linux-side `fakeram.so`, section 6b) if you want to rebuild them. Without
a compiler, the scripts say so and keep the shipped binary.

---

## 2. Install Wine Staging

Follow WineHQ's per-distro instructions: <https://wiki.winehq.org/Download>

You want `winehq-staging` (Ubuntu/Debian) or `wine-staging` (Fedora/Arch),
version **11.8 or newer** (we run 11.12; also tested on 11.9 and 11.10).

Verify:

```bash
wine --version
# expected: wine-11.12 (Staging)   (or higher)
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
git clone https://github.com/6im0n/lightroom-classic-on-linux.git
cd lightroom-classic-on-linux
./resources/scripts/wine/setup.sh
```

`resources/scripts/wine/setup.sh` does the following, idempotently (re-running skips
already-done steps):

1. Creates `wineprefix/` (`WINEARCH=win64`) and boots it.
2. Installs winetricks verbs: `corefonts ucrtbase2019 vcrun2019 msxml6 gdiplus
   dotnet48 atmlib fontsmooth=rgb dxvk`, **then** sets the Windows version to
   **11** — that order matters, because `dotnet48` resets the prefix back to
   Windows 7 (build 7601) and the Adobe installer's own OS check needs build
   ≥ 18362. If `winetricks -q win11` doesn't stick, the script writes the
   version keys directly and drops any per-prefix winver override.
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

The same source patch contains a stencil implementation of `PushLayer`
geometric masks, which restores Lightroom's GPU histogram fills. The launcher
enables it by default. To disable it if a layered UI regression appears:

```bash
D2D_LAYER_MASK=0 resources/scripts/lightroom/run-lightroom-classic.sh
```

The checked-in DLL is reproducible from the pinned Wine 11.10 commit:

```bash
# Reuse an existing checkout:
resources/scripts/wine/build-d2d1-lightroom.sh --source-dir /tmp/wine-src

# Or let the script clone Wine 11.10, build, and install into this prefix:
resources/scripts/wine/build-d2d1-lightroom.sh --install
```

The source patch is
`resources/patches/wine/d2d1-lightroom.patch`. The build script verifies commit
`2cac6ccf33c0807f374dc96f5a20e35a2da86157`, builds only `d2d1`, clears Wine's
builtin PE marker, and writes
`resources/stubs/binaries/d2d1-patched.dll`. The binary is built from Wine 11.10
source but is what runs here on Wine 11.12; rebuild it if Direct2D misbehaves
after a Wine upgrade (`start.sh` option `b`).

### The WebView2 `dcomp.dll`

Only needed for the Creative Cloud routes (menu 3/4). Edge WebView2 draws the
CC installer and sign-in pages. On wine-staging 11.11+, staging's DirectComposition
(`dcomp.dll`) answers `IDCompositionDevice3`, so WebView2 149+ takes its
DirectComposition path and its gpu-process aborts on a stubbed
`IDCompositionVisual::SetClipObject` (`E_NOTIMPL`). It restarts every ~4 s,
each restart maps another private ~300 MB copy of `msedge.dll`, and RAM runs
away until the machine stalls.

The fix is wine-staging **11.10**'s dcomp patchset (before that interface was
enabled), built from the same pinned Wine 11.10 source as `d2d1.dll`:
`resources/patches/wine/dcomp-webview2.patch` →
`resources/stubs/binaries/dcomp-webview2.dll`. Both CC install scripts run
`resources/scripts/wine/install-dcomp-webview2.sh`, which copies it into
system32 and sets `dcomp=native` for **`msedgewebview2.exe` only**
(`HKCU\Software\Wine\AppDefaults\msedgewebview2.exe\DllOverrides`); every
other program keeps wine's builtin. The same key pins `d3d11`, `dxgi` and
`d3d10core` to wine's builtin (wined3d) for WebView2 only: under DXVK 3.1 its
gpu-process leaks GPU buffers at ~400 MB/s (on an Intel iGPU that's system
RAM), while with wined3d memory stays flat. To rebuild the DLL:

```bash
resources/scripts/wine/build-dcomp-webview2.sh --install
```

The same scripts (and `run-creative-cloud.sh`, since WebView2 auto-updates into
a new folder) also run `resources/scripts/wine/realign-webview2.sh`.
`msedge.dll` is 314 MB with 512-byte file alignment, and wine can only share a
DLL between processes when its sections sit at page-aligned file offsets;
otherwise every process gets a private copy. The installer runs ~10-12 WebView2
processes, so that cost ~3 GB. `resources/scripts/stubs/pe_realign.py`
rewrites the DLL with 4 KB alignment (original kept as `msedge.dll.orig`), and
each process then keeps only ~26 MB private.

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
   needs it). By default the script downloads Microsoft's small online
   bootstrapper, which fetches the runtime during the install. For an offline
   install, put Microsoft's standalone runtime installer
   (`MicrosoftEdgeWebView2RuntimeInstallerX64.exe`, about 200 MB, "Evergreen
   Standalone Installer, x64" on
   <https://developer.microsoft.com/microsoft-edge/webview2/>) in
   `resources/installers/` and it's used instead. The CC scripts share the same
   helper, `resources/scripts/wine/install-webview2.sh`.
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
`resources/installers/`, then run the script below. Adobe's site detects Linux
and hides the Windows download, so switch your browser's user-agent to Windows
first (for example with the
[User-Agent Switcher](https://addons.mozilla.org/fr/firefox/addon/uaswitcher/)
Firefox extension).

```bash
./resources/scripts/creative-cloud/install-creative-cloud-live.sh
```

It installs WebView2 plus the WebView2 `dcomp.dll` (see
[The WebView2 `dcomp.dll`](#the-webview2-dcompdll)), then runs the bootstrapper
once under Windows 10 (2.14.0.82+ refuses Windows 7 at startup with
**error 21**, "Current OS is not supported"): you sign in and it downloads the
**current**
CC desktop app. The current build ships **CoreSync** (which provides
`CoreSync.exe` and `CCXProcess.exe`, the processes that render the Home / Apps /
Files / Fonts panels), so the panels work. After install it disables every
`AdobeGrowthSDK.dll` / `growthsdk.node` copy (they call the wine-unimplemented
`kernel32.SetThreadpoolTimerEx` and abort the Experience `node.exe`).

#### Back-version: the OFFLINE `ACCCx*.zip` (`install-creative-cloud.sh`, menu 4)

The offline `ACCCx*.zip` (from Adobe's
[direct download links page](https://helpx.adobe.com/download-install/apps/download-install-apps/creative-cloud-apps/download-creative-cloud-desktop-app-using-direct-links.html))
is a **back-version**. It installs
the CC core but then wants a self-update before it will install CoreSync — and
under wine that self-update sits behind a "click Update Now" bar that needs a
panel applet to render, which needs CoreSync: a catch-22. Symptom: the CC window
opens but the **panels never load** ("waiting" forever); `ACC.log` repeats
`OnProcessPingMiss`, `Could not get CCXP endpoint`, and
`Unable to launch CoreSync Process. No version of core sync is installed.`. Use
this route only if you already have the zip and don't need the panels.

#### Either route, then:

Launch the app with `./resources/scripts/creative-cloud/run-creative-cloud.sh` (menu 8). Sign in with
your Adobe ID. The pointer shows as a plain arrow over the sign-in page (the
`x11cursor.so` preload; wine can't apply WebView2's own cursors because it runs
in another process).
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
3. **Blocks Adobe's dunamis in-app tips.** The tip render path used to abort
   Lightroom with `BadMatch`/`X_CopyArea`; the script empties the dunamis
   feedback dir and locks it read-only, so the popup never renders.
4. **Disables wine's `discburning`.** LR enumerates CD/DVD burners when the
   Export dialog opens, and wine's implementation blocks the main UI thread —
   the whole app freezes. The override makes the probe fail fast.
5. **Installs the dialog-repaint fix** — a proxy `version.dll` in Lightroom's
   app dir (plus `version_orig.dll`, a copy of wine's builtin it forwards to),
   scoped to `Lightroom.exe` via a per-app DllOverride. It fixes the blank Copy
   Settings panel and the ghost rows in the Export preset tree; see
   `resources/stubs/sources/fix_ghost.c`. The binary ships prebuilt;
   `resources/scripts/stubs/build-stubs.sh` rebuilds it if you edit the source.

Re-run this script after a **wine upgrade**: step 5 re-copies `version_orig.dll`
from the wine you now have (KNOWN_ISSUES #7).

That's all the post-install steps; the `hnetcfg` stub and the patched
`d2d1`/`mfplat` from `setup.sh` already cover Classic (section 3).

---

## 6b. AI masking (Select Subject / Sky / Objects)

```bash
./resources/scripts/lightroom/install-ai-masking.sh     # menu option `a`
```

Optional but recommended, and idempotent. Without it, an AI mask does nothing
and the CameraRaw log ends with `*** Error: ML model not loaded ***`.

**Why it's needed.** Adobe runs its masking ONNX models through **WinML**
(`microsoft.ai.machinelearning` + `onnxruntime`), which feeds each model to
onnxruntime through `Windows.Storage.Streams` WinRT runtimeclasses. Wine only
half-implements them, and its async results don't expose **`IAsyncInfo`** —
WinML calls `get_Status` on them before reading the result, which is the
`0xc0000005` inside `microsoft.ai.machinelearning.dll`. Separately, onnxruntime
sizes its CPU inference arena to **total system RAM**, so on a 16 GB box it
tries to take all of it and OOMs (or freezes your desktop).

**What the script does:**

1. **Installs `winrt_inmemstream.dll`** (built with mingw-w64 from
   `resources/stubs/sources/winrt_inmemstream.c`) — an in-process WinRT DLL
   implementing `InMemoryRandomAccessStream`, `DataWriter` and
   `RandomAccessStreamReference`, **with `IAsyncInfo` on its async results**, and
   rewinding the stream in `OpenReadAsync` so WinML reads the whole model.
   Installs it into `system32`.
2. **Registers the three runtimeclasses** against it under
   `HKLM\Software\Microsoft\WindowsRuntime\ActivatableClassId`.
3. **Provides `fakeram.so`** (built with native gcc from
   `resources/stubs/sources/fakeram.c`) — an `LD_PRELOAD` shim that caps the RAM
   wine sees (`sysinfo` + `/proc/meminfo`) so the arena stays bounded. The
   launcher loads it automatically.
4. **Removes the AMD GPU spoof** from `dxvk.conf` if an earlier run left it
   there — see the warning in section 7.

Both binaries ship prebuilt, so no compiler is needed. The script rebuilds one
only when its source is newer, or when you run it with `MASKING_REBUILD=1`.
Rebuilding `winrt_inmemstream.dll` needs complete WinRT headers: Fedora's
`mingw64-headers` ships a stale `windows.storage.streams.idl`. Point `WINE_INC`
at the headers from WineHQ's `wine-staging-devel` package (default
`/opt/wine-staging/include/wine/windows`). On Fedora you can unpack them from
the RPM without installing it: `rpm2cpio wine-staging-devel-*.rpm | cpio -idm`.

Then launch normally and try **Develop > Masking > Select Subject**. Inference
runs on the **CPU** (Lightroom routes Intel parts to CPU), so expect it to take
a few seconds per mask.

Launcher knobs (section 8): `LR_MASKING=off` disables the preload,
`FAKERAM_GB=<N>` overrides the cap (default ≈60 % of real RAM, floor 6 GB).

> **After a wine upgrade**, the prefix update re-points some of those
> runtimeclasses back at wine's own builtins. The launcher re-asserts all three
> on every start; re-running this script fixes it too (KNOWN_ISSUES #7).

Full diagnosis trail — including the earlier, wrong "Adobe's models are
encrypted, dead end" conclusion — is in KNOWN_ISSUES #1.

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

### Optional Intel→AMD spoof (OFF by default — do not enable it)

The script has an opt-in adapter spoof, gated behind `LR_GPU_SPOOF=1`, which
appends `dxgi.customVendorId/DeviceId/DeviceDesc` ("AMD Radeon RX 6800 XT") to
`dxvk.conf`. It existed for one reason: Lightroom routes AI Masking inference to
CPU when it sees an Intel GPU (`Masking AI inference running on CPU: Intel
parts`), and that CPU path used to fail under wine, so pretending to be AMD
flipped LR onto the GPU/DirectML path.

**That reason is gone** — masking works on the CPU path since section 6b, and
the spoof is now actively harmful:

- the DirectML/vkd3d masking path it unlocks **hangs the integrated GPU**, and
- the AMD render path **blanks the Develop/Library histogram** entirely.

Leave it off. `install-ai-masking.sh` strips it out of `dxvk.conf` if an older
run set it. Real-Intel + GPU-on gives correct photo colours, a properly filled
histogram (KNOWN_ISSUES #2) and working masking.

---

## 8. Run Lightroom Classic

```bash
./resources/scripts/lightroom/run-lightroom-classic.sh
```

Expected: the Library module loads with your catalog. Click into **Develop** to
edit; sliders and manual masks apply in real time.

It also accepts two flags: `--vdesktop[=WxH]` (run inside a wine virtual
desktop — menu option 8) and `--dpi=N` (menu option `d` passes this).

The launcher is self-contained and configurable via env vars:

- **`LR_DPI`** (default `144`) — HiDPI UI scaling, written to the prefix's
  `HKCU\Control Panel\Desktop\LogPixels`. `96`=100%, `120`=125%, `144`=150%,
  `192`=200%. Set `LR_DPI=96` to disable scaling.
- **`LR_DRIVER`** (`auto`|`wayland`|`x11`, default `auto`) — graphics driver.
  `auto` picks native `winewayland.drv` on a Wayland session and `x11` on an
  X11 session (or when wine has no Wayland driver); the launcher prints which
  one and why. Wayland is smoother and handles fractional scaling itself, which
  also avoids the Preferences freeze X11 hits at 125%/150% scaling
  (KNOWN_ISSUES #12). With it the launcher also preloads `wlstack.so`, which
  keeps menus above the GPU-drawn photo (`LR_WLSTACK=0` turns it off). `x11`
  goes through Xwayland on a Wayland session. Without
  `LR_DRIVER`, the choice saved with `start.sh` option `w` is used. Switching
  drivers restarts the wine session automatically.
- **`LR_KILL_STALE`** (default `1`) — run `wineserver -k` for the prefix before
  launching and wait for the processes to be reaped. Lightroom aborts on
  shutdown (`KERNEL32.dll.UnregisterApplicationRecoveryCallback`, KNOWN_ISSUES
  #5) and leaves processes holding locks that deadlock the next launch. Set
  `0` only to attach a debugger to a running instance.
- **`LR_TIPS`** (default `0`) — before each launch,
  `resources/scripts/lightroom/disable-tips.sh` (plain awk) keeps tips, walkthroughs and
  feature onboarding off; they have frozen Lightroom under the Wayland driver.
  It sets every preference whose name contains "Onboarding" or "Walkthrough"
  (any case) from `false` to `true`, so flags added by future Lightroom
  versions are covered too, and adds the known ones (`AgTipsDlg_TurnOffTips`,
  the per-module `…_Showed_Walkthroughs`, …) when missing. Keys that also
  contain "always", "should", "enable" or "force" are left alone, because
  `true` would turn onboarding on for them. The file is
  `wineprefix/drive_c/users/<you>/AppData/Roaming/Adobe/Lightroom/Preferences/Lightroom Classic CC 7 Preferences.agprefs`;
  a new install only has it after its first run. Set `1` to keep the tips.
- **`LR_KILL_ON_EXIT`** (default `1`) — once Lightroom exits, stop the prefix's
  wine session (`wineserver -k`, then wait for it). Otherwise wineserver,
  services.exe, rpcss, plugplay, lsass and WebView2's `MicrosoftEdgeUpdate.exe`
  keep running until the next launch. It's skipped while the Creative Cloud app
  (`Creative Cloud.exe`) is running in the same prefix. Set `0` to leave the
  session up.
- **`LR_SCREEN_DEPTH`** (default `32`) — writes
  `HKCU\Software\Wine\AppDefaults\Lightroom.exe\X11 Driver\ScreenDepth`. Pins
  wine to Xwayland's depth-32 ARGB visual so opening **Import** doesn't abort
  with `BadMatch`/`X_CopyArea` (§9, KNOWN_ISSUES #8). `0` skips the write,
  `24` restores wine's default — and the crash.
- **`LR_MASKING`** (`auto`|`off`, default `auto`) and **`FAKERAM_GB`** — AI
  masking (§6b). `auto` preloads `fakeram.so` when it's built, capping the RAM
  wine reports to ≈60 % of real RAM (floor 6 GB) so onnxruntime's arena stays
  bounded; `FAKERAM_GB=<N>` sets the cap yourself, `off` disables the preload.
- **`D2D_LAYER_MASK`** (default `1`) — enables the stencil `PushLayer`
  geometric-mask path in the patched `d2d1.dll`, which is what fills the
  histogram (KNOWN_ISSUES #2). Set `0` if a layered UI element regresses.
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

Then relaunch. (Tested across 11.9 → 11.10 → 11.12 upgrades.)

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

### "The explorer process failed to start" / "no driver could be loaded"

The launcher restarts the wine session when the graphics driver changes and
starts wine's desktop process before Lightroom, which covers the known causes
(a leftover session from the other driver, and Lightroom's processes racing to
start the Wayland desktop). If it still happens, for example after a crash,
kill the session and relaunch:

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

**Import** — Xwayland advertises a depth-24 default visual *and* a depth-32 ARGB
visual (wine traces it as `init_visuals default visual 23 class 4 argb 7c`).
Wine composites part of the UI through the ARGB visual, and `X_CopyArea` between
drawables of *different depth* is a protocol error. Opening Import hits that
copy, Xlib's default handler aborts, Lightroom dies.

**Default fix (automatic):** `run-lightroom-classic.sh` pins wine's default
visual to the depth-32 ARGB one, so every drawable has the same depth:

```
HKCU\Software\Wine\AppDefaults\Lightroom.exe\X11 Driver → ScreenDepth = "32"
```

The launcher writes it on every start (per-app, so nothing else in the prefix is
touched). `LR_SCREEN_DEPTH=0` skips the write and keeps whatever the prefix has;
`LR_SCREEN_DEPTH=24` restores wine's default — and the crash. Launching by hand?
Set the key once with the command above, or:

```bash
WINEPREFIX=$PWD/wineprefix wine reg add \
  'HKCU\Software\Wine\AppDefaults\Lightroom.exe\X11 Driver' \
  /v ScreenDepth /t REG_SZ /d 32 /f
```

> Earlier revisions of this guide claimed `WINE_X11_NO_MITSHM=1` was the fix.
> **It never worked** — wine has no such variable (it was only ever requested,
> wine bug 43893; no `MITSHM` string exists in the wine 11.12 binaries or
> sources). The export was removed from the launcher.

**Fallback:** if the depth-32 visual isn't enough on your setup, run inside a wine
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

### AI Masking (Select Subject / Sky / Objects) does nothing

`*** Error: ML model not loaded ***` in the CameraRaw log means the WinRT stream
DLL isn't in place. Run section 6b (`install-ai-masking.sh`, menu `a`) and
relaunch. If it worked before and stopped after a **wine upgrade**, the prefix
update reset the runtimeclass registrations — the launcher normally re-asserts
them, otherwise re-run the same script (KNOWN_ISSUES #1 and #7). Check what the
prefix currently has:

```bash
grep -c 'winrt_inmemstream\.dll' wineprefix/system.reg     # expected: 3
```

If instead the desktop **freezes or OOMs** when a mask starts, `fakeram.so`
isn't being preloaded — onnxruntime then sizes its arena to your total RAM.
Confirm the launcher prints `==> AI masking: fakeram.so loaded …`, and lower the
cap by hand if needed (`FAKERAM_GB=8`).

If you enabled the AMD GPU spoof, remove it — it pushes masking onto DirectML,
which hangs the iGPU (§7).

### Histogram has coloured outlines but no filled body, with GPU on

wine's Direct2D `PushLayer`/`PopLayer` are unimplemented stubs, so the
layer-enclosed translucent channel fills are dropped (the outline strokes, drawn
outside any layer, still render). NOT a DXVK issue — see KNOWN_ISSUES #2 for the
full trace. Fixed by the patched `d2d1.dll` this repo ships (section 3); if you
see the fill-less histogram, that DLL is missing or `D2D_LAYER_MASK=0` is set.

### Copy Settings panel blank / Export preset tree leaves ghost rows

wine does not erase removed rows in Export's owner-data listview, and Adobe's
subclassed Copy Settings checkboxes drop `WM_PAINT` without drawing. Fixed by
the proxy `version.dll` that `install-lightroom-classic-fixes.sh` installs into
Lightroom's app dir (KNOWN_ISSUES #6). Re-run that script if the dialogs start
ghosting again — e.g. after a wine upgrade left `version_orig.dll` stale.

### Export window freezes the whole app

wine's `discburning.dll` (IMAPI2) blocks the main UI thread while LR enumerates
CD/DVD burners on Export open. The launcher exports
`WINEDLLOVERRIDES="discburning=;…"` and the fixes script writes the same
override to the prefix registry, so the probe fails fast instead
(KNOWN_ISSUES #6b).

### Want to trace the ML-masking path yourself

Useful if masking still misbehaves on your setup after section 6b.
`resources/scripts/lightroom/debug-lightroom-classic-ml.sh` clears the wine
session, then launches LrC with the channels that matter for the ML path
(`+loaddll,+seh,+combase,+ole,+module`), logging to `/tmp/lrc-ml-debug.log`.
Trigger a mask (Develop > Masking > Select Sky), close LrC, and it prints a
summary itself: which ML/stream DLLs loaded and in what order, missing WinRT
classes, failed imports, access violations, and the CameraRaw WML verdict.

It force-sets `WINEDEBUG` (a value exported in your shell would otherwise hide
those channels); override deliberately with `ML_WINEDEBUG=…`.
