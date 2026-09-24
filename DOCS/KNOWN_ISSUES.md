# Known Issues

Limitations and rough edges of Adobe **Lightroom Classic** under Wine, as of
wine 11.12 staging + DXVK 2.7.1 + vkd3d-proton 3.0.0 on Intel Iris Xe (Arch /
GNOME). None of these block the core workflow — install, launch, the Develop
module, manual edits, GPU acceleration, **AI masking** and the **filled
histogram** all work now.

Entries #1 (AI masking), #2 (histogram fill), #6 (dialog ghosting), #6b (Export
freeze), #8 (Import crash), #9 (CC installer RAM), #10 (CC sign-in page) and #11 (CC app startup crash) are **fixed** and kept here for the diagnosis
trail — what the real cause turned out to be, and which script applies the fix.
Only **HDR** (#3) is still a hard limitation; the rest is log noise (#4) and
maintenance you need to know about (#5 stale wineserver, #7 wine upgrades).

---

## 1. AI Masking (Select Subject / Sky / Objects) — FIXED (2026-06-02)

**Old symptom:** triggering an AI mask produced nothing; the CameraRaw log ended
with `*** Error: ML model not loaded ***`, sometimes preceded by a `0xc0000005`
inside `microsoft.ai.machinelearning.dll`.

**Real root cause — a wine gap after all, in WinRT, not in Adobe's crypto.**
Adobe runs the masking ONNX models through **WinML**
(`microsoft.ai.machinelearning` + `onnxruntime`), and WinML feeds each model to
onnxruntime through a chain of `Windows.Storage.Streams` WinRT runtimeclasses
that wine only half-implements. Two independent blockers:

1. **The WinRT stream chain.** WinML needs
   `InMemoryRandomAccessStream`, `DataWriter` and
   `RandomAccessStreamReference`. Wine's coverage is partial, and — critically —
   its async results do not expose **`IAsyncInfo`**, which WinML's await path
   calls (`get_Status`) before touching the result: that null-deref *is* the
   `0xc0000005`. On top of that, `OpenReadAsync` must hand back a stream
   rewound to position 0 or WinML reads a truncated model.
2. **onnxruntime sizes its CPU inference arena to TOTAL system RAM.** On a 16 GB
   box it logs `CPU memory (15.305 GB)` and tries to take essentially all of it
   — OOM, or a frozen desktop, before any inference happens.

**The fix — `install-ai-masking.sh` (menu option `a`):**

- Builds **`winrt_inmemstream.dll`**
  (`resources/stubs/sources/winrt_inmemstream.c`, mingw-w64), a small in-process
  WinRT DLL implementing all three runtimeclasses **with `IAsyncInfo` on its
  async results** and a rewind in `OpenReadAsync`; installs it into `system32`
  and points the three `HKLM\…\WindowsRuntime\ActivatableClassId` entries at it.
- Builds **`fakeram.so`** (`resources/stubs/sources/fakeram.c`, native gcc), an
  `LD_PRELOAD` shim that caps the RAM wine reports (`sysinfo` +
  `/proc/meminfo`) so the arena is bounded. `run-lightroom-classic.sh` loads it
  automatically (`LR_MASKING=auto`, default cap ≈60 % of real RAM, floor 6 GB;
  override with `FAKERAM_GB=<N>`, disable with `LR_MASKING=off`).

Masking then runs on the **CPU** path (LR sees an Intel iGPU and picks CPU) and
produces real masks.

> **Do not use the AMD GPU spoof with masking.** `LR_GPU_SPOOF=1` (GUIDE §7)
> flips LR off its `Masking AI inference running on CPU: Intel parts` decision
> onto DirectML/vkd3d, which **hangs the integrated GPU** — and it blanks the
> histogram (#2). `install-ai-masking.sh` strips the spoof out of `dxvk.conf`
> for you. Normal GPU acceleration for Develop is unaffected.

> **The earlier conclusion in this file was wrong.** It read: *"Adobe's models
> are encrypted `secured_file` blobs; the failure is inside Adobe's proprietary
> WFML decrypt-then-load step — a definitive stop point, not a wine bug."* The
> encrypted blobs are real, but Adobe's decrypt path was never the blocker: it
> never got that far, because the model never arrived through the broken WinRT
> stream chain. The supporting probes still hold — onnxruntime (v1.23.0) loads
> under wine on both CPU and DML, `bcrypt` works, and the 42 `.data` models on
> disk match `Index.dat`.

**After a wine upgrade** the prefix update re-points some of those
runtimeclasses back at wine's builtins (see #7). The launcher re-asserts all
three on every start; re-running `install-ai-masking.sh` also fixes it.

> **AI Denoise** is a different Adobe code path and has not been verified here.

---

## 2. Histogram drawn without its filled body, GPU on — FIXED (2026-06-10)

**Old symptom:** with GPU acceleration enabled (Preferences > Performance), the
Develop/Library histogram draws the R/G/B/luminance curve **outlines** in colour
but is missing its translucent **filled body** — a flat grey panel with coloured
lines instead of the usual filled, blended channel "mountains". The **photo image
colors themselves are correct** — only the histogram fill is affected.

**Cause (corrected 2026-06-10 — it is NOT DXVK).** Traced live with
`WINEDEBUG=+fixme`: the culprit is **wine's Direct2D (`d2d1`) `PushLayer` /
`PopLayer` being unimplemented stubs**. Lightroom draws each translucent
channel fill inside a `PushLayer`(opacity + geometry mask)…`PopLayer` pair; the
curve outlines are plain `ID2D1RenderTarget::DrawGeometry` calls drawn *outside*
any layer. wine 11.10's `d2d_device_context_PushLayer`/`PopLayer` are pure stubs
for normal targets (they only record into command lists, never composite an
opacity/mask layer), so the layer-enclosed fills are dropped while the outline
strokes render fine — exactly the observed picture. The earlier "DXVK
additive-blend limitation" note was wrong: latest DXVK (2.7.1, the newest
release) is already installed, and dropping in another build's `d2d1.dll`
(GE-Proton's) does not start LR (ABI/effect-registration mismatch against wine
11.10).

**Fixed for Lightroom:** this repository carries a Wine 11.10 source patch that
rasterizes `PushLayer` geometric masks into a D3D11 stencil buffer and tests
subsequent draws against it. The launcher enables the path by default. The patch
intentionally implements only the geometric mask needed by Lightroom; layer
opacity and opacity brushes remain unimplemented. Build details are in GUIDE
section "The patched `d2d1.dll`". Disable it if a layered UI regression appears:

```bash
D2D_LAYER_MASK=0 resources/scripts/lightroom/run-lightroom-classic.sh
```

**Follow-up fix (2026-07-26): blank thumbnail grids.** The first version of the
patch rasterised each mask under `maskTransform` *alone*. Direct2D composes that
matrix with the world transform in effect at `PushLayer`, so every layer pushed
under a non-identity transform — the HiDPI UI scale (`LR_DPI=144`) plus the
per-cell offsets of the Library and Import thumbnail grids — got its mask
rasterised somewhere off-cell. The stencil test then rejected the whole layer
content: grid cells drew their frame with a blank interior, and only a hovered
cell flickered in. Develop's main preview was unaffected because it is drawn
outside any layer. The patch now composes `maskTransform` with the world
transform captured at push time, and `PopLayer` erases with that same snapshot
so nested layers cannot leak stencil levels.

**Fallback (only if you disable the patch):** turning GPU acceleration **off** in
Preferences > Performance also gives a full-colour filled histogram, at the cost
of much slower editing. With the patched `d2d1.dll` in place you don't need it —
GPU on and the histogram fills correctly.

> The Intel→AMD GPU spoof (`LR_GPU_SPOOF=1`) blanks the histogram entirely, and
> hangs the iGPU when masking runs (#1). It is off by default and
> `install-ai-masking.sh` removes it if an older run left it in `dxvk.conf`.
> Its original purpose — pushing masking ML onto the GPU, because Adobe routes
> Intel parts to CPU — is obsolete: masking now works on the CPU path.
---

## 3. HDR is not available

If your display panel is HDR-capable, but HDR editing in LrC needs native `winewayland.drv` **plus**
compositor HDR. Since wine 11.18 the native Wayland driver runs Lightroom here
and is the default on Wayland sessions (#12), but HDR through it has not been
verified yet. On the X11 path (Xwayland) the monitor EDID / HDR can't reach
wine at all.

The blank-colorimetry log lines you may see are cosmetic for SDR work (Lightroom
uses sRGB / ICC color management). The launcher silences them by default.

---

## 4. Cosmetic log noise (silenced by the launcher)

`run-lightroom-classic.sh` suppresses these by default; they're all harmless and
listed here so you know what they are if you turn logging back on:

- **`RoGetActivationFactory ... Failed to find library`** for WinRT runtimeclasses
  wine doesn't implement (`Windows.Media.Core.MediaSource` and friends). Used for
  video/tutorial playback paths; LR falls back fine. The three
  `Windows.Storage.Streams` classes are **not** in this category any more — they
  are supplied by `winrt_inmemstream.dll` and are what makes AI masking work
  (#1); if you see that error naming one of *those*, masking is not installed or
  a wine upgrade reset its registration (#7).
- **Adobe-internal CLSID "class not registered"** (`e26b366d-…` and similar).
- **EDID / colorimetry / "Failed to parse display metadata"** from DXVK — wine
  has no monitor EDID in the registry on the X11 path (see #3).
- **UI "unknown msg 06xx"** from common controls (header/listview/trackbar/
  progress).

---

## 5. wine missing export: `KERNEL32.dll.UnregisterApplicationRecoveryCallback`

Wine ships `RegisterApplicationRecoveryCallback` and
`ApplicationRecoveryFinished` but not `UnregisterApplicationRecoveryCallback` —
and `Lightroom.exe` imports all three. Wine fills the missing import with an
aborting stub, so **closing Lightroom kills the thread mid-shutdown**:

```
wine: Call from ... to unimplemented function
      KERNEL32.dll.UnregisterApplicationRecoveryCallback, aborting
```

The window vanishes but the process stays alive holding its locks, and the next
launch deadlocks against it with
`err:sync:RtlpWaitForCriticalSection ... wait timed out`. Adobe's background
services (Adobe Desktop Service, AdobeIPCBroker, CoreSync) linger the same way,
as does a crashed native-Wayland attempt (`LR_DRIVER=wayland`).

**Handled automatically:** `run-lightroom-classic.sh` runs `wineserver -k` for
the prefix before every launch and waits for the processes to be reaped. Only
running processes are affected — the install, settings and shader cache on disk
are untouched, and Lightroom is single-instance anyway. Set `LR_KILL_STALE=0` to
skip it (e.g. to attach a debugger to a running instance).

The launcher also stops the session after Lightroom exits (`LR_KILL_ON_EXIT`,
on by default, skipped while the Creative Cloud app is running), so nothing is
left running between launches. With the current Lightroom Classic on wine
11.18, a normal close shuts down cleanly in about 15 seconds and never reaches
the aborting import; the pre-launch cleanup stays as a safety net.

By hand, or for the Creative Cloud app (`start.sh` option `k`):

```bash
WINEPREFIX=$PWD/wineprefix wineserver -k
```

---

## 6. Dialog "ghosting" / blank panels: Copy Settings + Export preset tree

**Symptoms (two faces of one bug):**

- **Copy Settings dialog** (Develop > Copy…, and Copy/Paste settings): the
  left-hand category panel (the checkbox list of setting groups) renders
  **blank** or only partially painted. Clicking the empty area does nothing
  useful; the controls are there but not drawn.
- **Export preset tree** (File > Export, left-side preset/preset-group tree):
  **stale text "ghosts"** when you expand/collapse a group — old labels and
  checkboxes stay painted under/over the new layout. Resizing the dialog forces
  a full repaint and clears it, which confirms it's a paint bug, not a data bug.

**Root causes — two broken paint paths** (verified live by driving the dialogs
under automation, wine 11.10 staging).

The Export preset tree is **one** `SysListView32` with
**`LVS_OWNERDATA` (virtual) + `LVS_OWNERDRAWFIXED` (owner-draw)** (style
`0x740d`). Collapsing a group shrinks the item count via `LVM_SETITEMCOUNT`;
wine updates the count correctly (`LVM_GETITEMCOUNT` confirms) and repaints
the surviving rows, but **never erases the area the removed rows occupied** —
its item-geometry path is broken for this style combination
(`LVM_GETITEMRECT` returns empty rects), so the computed erase region is
empty, and even a forced `RedrawWindow(RDW_ERASE)` is a **no-op** on this
control. The old row pixels stay → ghosts.

Copy Settings is different: its left-panel `Button` checkbox controls receive
`WM_PAINT` through an Adobe subclass that returns without
`BeginPaint`/`ValidateRect`, so they never draw a pixel (their update region
stays dirty forever; LR burns idle CPU on the ignored paint requests). Forced
invalidation, resizing, restyling, disabling themes, and forcing `WM_PAINT`
through wine's builtin `Button` proc all fail — they take or rely on the same
broken path. (The right-hand mask list renders because those checkboxes sit
under normal `AfxWnd140u` container views, not under the broken left
`BS_GROUPBOX` parent.)

**FIXED (proxy `version.dll` paint hook — both verified live by automation).**
`install-lightroom-classic-fixes.sh` drops a proxy `version.dll` into
Lightroom's install dir (built from `resources/stubs/sources/fix_ghost.c` +
`version-proxy.def` by `resources/scripts/stubs/build-stubs.sh`). It forwards
version's 16 exports to `version_orig.dll` (a copy of wine's builtin placed
beside it) and installs a `WH_CALLWNDPROC` hook on Lightroom's UI thread that
acts **only inside modal dialogs** — a top-level `WS_POPUP` MFC `Afx:*` window
or a `#32770`, **never** the GPU-composited `AgWinMainFrame` *nor its child
`Afx:*` views*, which go black if drawn on:

- **Export preset tree** — on `LVM_SETITEMCOUNT` to a dialog `SysListView32`,
  the hook **fills the listview's client area with its background colour
  itself** (`FillRect` with `LVM_GETBKCOLOR`) and invalidates, so wine
  repaints the real rows over the fill (its own `RDW_ERASE` is a no-op here).
  Coalesced and flushed once per burst by a low-priority `WM_TIMER`.
- **Copy Settings checkboxes** — the hook **subclasses** each checkbox in a
  checkbox-heavy dialog (≥20 visible checkboxes, so it targets Copy Settings
  and nothing else) and **owns its `WM_PAINT`**: it draws the box
  (`DrawFrameControl` with the real `BM_GETCHECK` state) and label (`DrawText`,
  the control's own font, the parent's `WM_CTLCOLORBTN` background) and
  validates. Owning every paint means the control stays drawn through
  hover/click repaints — an earlier approach that only repainted on *observed*
  messages drew them once but they blanked again on mouse-over. Late-created
  controls are caught by a light repeating sweep while the dialog is open.

Set `FIXGHOST_LOG=<path>` (and optionally `FIXGHOST_DEBUGFILL=1`) in
Lightroom's environment to trace the hook.

Three earlier failure modes of this approach, and how they were solved:

- **32-bit Adobe helpers broke** when the proxy was loaded process-wide via
  `WINEDLLOVERRIDES=version=n` from `system32`. Solved by **scoping**: the
  proxy lives in Lightroom's own app dir — first in the native DLL search
  path, so only exes in that dir (all 64-bit) can load it — plus a per-app
  `HKCU\Software\Wine\AppDefaults\Lightroom.exe\DllOverrides`
  `version = native,builtin` override and an exe-name check in `DllMain` so
  the hook only installs inside `Lightroom.exe`.
- **The main window went black.** Two builds blacked out the GPU-composited
  main UI: the first watched `Button`/`Static` children everywhere; a later
  one matched dialogs by the bare `Afx:*` class — but that is the *generic*
  MFC class, also used by child views inside `AgWinMainFrame`, and the
  `RDW_ERASE`-on-parents path erased them. Solved by (a) tightening
  dialog-detection to `WS_POPUP` top-level `Afx:*` / `#32770` only, and
  (b) removing the broad erase-parent path entirely (it was based on a wrong
  "vacated child" theory and neither real bug needs it).
- **Copy Settings blanked on hover.** Repainting only when a paint message was
  *observed* lost the race with Adobe's subclass on mouse-over. Solved by
  subclassing the controls so we own `WM_PAINT` outright.

**Other dead ends (for the record):**

- **`WS_EX_COMPOSITED`** double-buffering — unimplemented in wine (no-op).
- **`AppInit_DLLs`** injection of a repaint-fixer — **not supported** by wine
  staging (0 references); DipCrai's repo relied on Proton for this.
- **Inline x64 hooking** of `user32` geometry functions (12-byte movabs+jmp
  trampoline, DipCrai's CreateWindowExW technique): wine's `user32` wrappers are
  thin jmp-thunks into `win32u` whose first bytes aren't safely relocatable —
  the trampoline **crashes** (`rip:ffffffffffffffff`).
- **Fractional/integer display scaling, MIT-SHM toggle, uxtheme, virtual
  desktop** — none changed the repaint behavior (ruled out as the cause).

**Fallback if the hook misbehaves:** delete `version.dll` and
`version_orig.dll` from the Lightroom install dir (loading then falls back to
the builtin) and use the old workaround — resize the dialog (drag any edge) to
force a full repaint; the panel fills in / the ghosts clear. The settings
underneath are always correct and selectable; the bug is cosmetic. The
upstream fix would be a wine source patch to comctl32's owner-data listview
item-geometry/erase path (or real `WS_EX_COMPOSITED` support).

### 6b. Export window freeze (SEPARATE bug — FIXED)

Distinct from the ghosting above, opening the **Export** dialog used to **freeze
the whole app** (lots of dumps/log). Cause: wine's **`discburning.dll`**
(IMAPI2) — LR enumerates CD/DVD burners on Export open and wine's implementation
**blocks the main UI thread** on an object that never signals. **Fixed** by
disabling `discburning`: `run-lightroom-classic.sh` exports
`WINEDLLOVERRIDES="discburning=;…"` and
`install-lightroom-classic-fixes.sh` writes the same override to the prefix
registry. No user action needed.

---

## 7. A wine upgrade silently undoes parts of the setup

Upgrading wine (e.g. 11.9/11.10 → 11.12) re-runs the prefix update on the next
launch, and that rewrites registry areas this project configures. Symptoms are
features that "used to work" going quiet again — nothing crashes loudly.

**What gets reset**

- **WinRT stream classes (AI masking).** The prefix update rewrites
  `HKLM\Software\Microsoft\WindowsRuntime\ActivatableClassId` and points
  `Windows.Storage.Streams.DataWriter` back at wine's `wintypes.dll` and
  `RandomAccessStreamReference` at wine's `windows.storage.dll` (wine 11.12 ships
  both), while `InMemoryRandomAccessStream` keeps pointing at ours — a mixed
  stack. `run-lightroom-classic.sh` now re-asserts all three at launch; running
  `install-ai-masking.sh` again also fixes it.
- **`version_orig.dll`.** The dialog-repaint proxy (#6) forwards to a copy of
  wine's builtin `version.dll` taken at install time. After an upgrade that copy
  is stale; the launcher warns, and `install-lightroom-classic-fixes.sh`
  re-copies it from the wine you currently run.

**What does *not* get reset** — the per-app keys under
`HKCU\Software\Wine\AppDefaults\Lightroom.exe` (`ScreenDepth`, `version`
override) and `HKCU\Software\Wine\DllOverrides` (`d2d1`, `discburning`) survive
prefix updates.

**Native DLLs are built against a pinned wine tree.** `d2d1-patched.dll` comes
from wine **11.10** source (`resources/patches/wine/d2d1-lightroom.patch`), and
the checked-in binary is the build that is running here on wine 11.12. It keeps
working across minor upgrades, but if Direct2D misbehaves after one, rebuild it
against the wine you actually run (`start.sh` option `b`).

**After every wine upgrade:**

```bash
WINEPREFIX=$PWD/wineprefix wineserver -k          # stale server blocks launches
resources/scripts/lightroom/install-lightroom-classic-fixes.sh
resources/scripts/lightroom/install-ai-masking.sh  # if masking is installed
```

---

## 8. Import window aborted the app (FIXED)

Opening **Library > Import** killed the process with an Xlib abort
(`BadMatch`, `X_CopyArea`, opcode 62) because Xwayland offers a depth-24 default
visual next to a depth-32 ARGB one and wine copied between them. Fixed by
pinning wine's visual to depth 32 for `Lightroom.exe`
(`HKCU\Software\Wine\AppDefaults\Lightroom.exe\X11 Driver` → `ScreenDepth=32`),
written by the launcher on every start. Full detail in GUIDE §9.

The `WINE_X11_NO_MITSHM=1` workaround previously documented here and in the
GUIDE **never did anything** — wine has no such variable (wine bug 43893 was
never implemented; the string does not exist in the wine 11.12 binaries).

## 9. Creative Cloud installer eats all RAM (FIXED)

On wine-staging 11.11+ the CC installer's sign-in page (Edge WebView2) climbed
past 15 GB of RAM within a minute. Its gpu-process crashed every ~4 s
(`0x80000003` in `msedge.dll`, one crash dump per restart). The cause is
wine-staging's dcomp patchset: patch 0067 "Allow IDCompositionDevice3
interface" (2026-06-08) makes Chromium take its DirectComposition path, which
then aborts on the stubbed `IDCompositionVisual::SetClipObject`. Every restart
maps another private ~300 MB copy of `msedge.dll`.

Not the cause (all tested): wine 11.12 vs 11.17/11.18, WebView2 149 vs 153,
Windows 7 vs 10, GPU flags, DXVK vs wined3d, transparent hugepages.

Fixed by giving `msedgewebview2.exe` a dcomp.dll built from wine-staging
11.10's patchset (GUIDE §3, "The WebView2 `dcomp.dll`").

With the crash loop gone, a slower leak showed up: under DXVK 3.1 the WebView2
gpu-process kept allocating GPU buffers (~400 MB/s of shared memory, 16 GB in
under a minute). `install-dcomp-webview2.sh` also switches WebView2 alone to
wined3d, which keeps it flat.

A second, steady cost: wine gave every WebView2 process its own ~300 MB copy of
`msedge.dll` (512-byte file alignment can't be memory-mapped), about 3 GB in
total. `realign-webview2.sh` page-aligns the DLL so the processes share it.

After a wine upgrade, check for leftover processes from the old wine version
(`ps aux | grep 'C:\\windows'`): the new `wineserver -k` can't reach them, and
a stale session held ~10 GB of GPU memory during this investigation.

## 10. Creative Cloud sign-in page: flicker and pointer

The WebView2 sign-in page used to flicker constantly and hide the mouse
pointer.

- **Flicker: fixed.** `install-dcomp-webview2.sh` makes `msedgewebview2.exe`
  alone report Windows 7 (per-app `Version`), which avoids Chromium's
  flickering Windows 8+ presentation path. Adobe's installer keeps Windows 10,
  which it needs to avoid error 21.
- **Invisible pointer: worked around.** WebView2 runs in a different process
  than the Adobe window around it, and wine can't apply a cursor from another
  process ("icon handle ... from other process"). The window was left with
  wine's blank cursor. `resources/stubs/binaries/x11cursor.so`, preloaded by the
  CC scripts, swaps that blank cursor for an arrow. The pointer stays an arrow
  over text fields and links.

## 11. Creative Cloud app stuck on "Initializing", then crashes (FIXED)

Two separate causes, both handled by `run-creative-cloud.sh` on every launch:

- **Missing toast notifications.** Creative Cloud 6.10 asks for the WinRT
  `Windows.UI.Notifications.ToastNotificationManager` at startup. wine has no
  implementation, so `RoGetActivationFactory` fails with `REGDB_E_CLASSNOTREG`
  and `Creative Cloud.exe` dereferences the NULL factory (access violation at
  `Creative Cloud.exe+0x65f9e`). `winrt_toast.dll`
  (`resources/stubs/sources/winrt_toast.c`, installed by
  `install-winrt-toast.sh`) provides the factory and reports notifications as
  disabled.
- **GrowthSDK back in place.** The install script only disables
  `AdobeGrowthSDK.dll` / `growthsdk.node` / `HDUWP.dll` after Adobe's
  bootstrapper exits, and CC reinstalls them when it updates. They abort the
  panel host (`node.exe`). `disable-cc-crashers.sh` now runs before every launch.

## 12. Graphics driver: Wayland by default, X11 as fallback

On a Wayland session the launcher now uses wine's native Wayland driver
(`LR_DRIVER=auto`). With wine 11.18 it starts Lightroom reliably and feels
smoother than X11 through Xwayland. X11 sessions keep the X11 driver. `start.sh`
option `w` (or `LR_DRIVER=x11|wayland`) switches it.

Why not X11 everywhere: under **fractional scaling** (125%, 150%...) on a
Wayland session, **Edit > Preferences freezes Lightroom** with the X11 driver.
The dialog has a fixed size (for example 1374×1229); the compositor sizes X11
windows in whole logical pixels, so at 125% the height becomes 1230. Lightroom
resizes it back, the compositor rounds it again, and the main thread spins in
`SetWindowPos` forever (its hang monitor logs `main thread pulse not
received`). The Wayland driver handles the scale itself and doesn't loop. On
X11 the workarounds are the virtual desktop (menu `8`), an integer scale
(100%/200%), or the compositor's "let X11 apps scale themselves" option
(GNOME: `xwayland-native-scaling`; KDE: "Apply scaling themselves").

Menus drawn under the photo (fixed): wine's Wayland driver makes Lightroom's
GPU-drawn areas (the photo, the histogram) and its menus sub-surfaces of the
main window, and places each menu directly above the main window, which is the
bottom of the stack. The photo then painted over any menu overlapping it
(`wayland_surface_reconfigure_subsurface` in `dlls/winewayland.drv`, still the
same in wine master). `resources/stubs/binaries/wlstack.so`
(`resources/stubs/sources/wlstack.c`), preloaded by the launcher with the
Wayland driver, drops that one "place above the parent" request. New
sub-surfaces start at the top of the stack, so menus stay above the GPU
surfaces. `LR_WLSTACK=0` turns it off.

Tips and walkthroughs: once, a tip popping up froze Lightroom under Wayland
(main thread blocked). It didn't happen again in later runs, but the launcher
now keeps tips off (`LR_TIPS`, GUIDE §8): every "…Onboarding…" /
"…Walkthrough…" preference is set to `true`, the same state Lightroom saves
when you tick "Turn off tips" or finish a walkthrough. Their dimming overlay is
a separate top-level window under Wayland, which is why, when a walkthrough
did show, clicks stayed blocked after it closed. The "What's New" screen can't
be turned off this way: Lightroom resets `shouldShowWhatsNew` itself.

Two things the launcher handles for Wayland: switching drivers restarts the
wine session, and wine's desktop process is started before Lightroom, because
Lightroom's first processes otherwise race to start it and one fails with
"The explorer process failed to start".

## 13. Map module freezes Lightroom (open)

Opening **Map** starts Lightroom's embedded Chromium (`Adobe Lightroom CEF
Helper.exe`) and Lightroom stops responding. With the Wayland driver the main
thread spins in wine's input-method code (`WM_IME_NOTIFY` →
`NtUserQueryInputContext`, tens of thousands of calls a second). Hiding the
compositor's text-input protocol from wine stops that loop, but then
`Lightroom.exe` grows past 5 GB plus several GB of GPU buffers until RAM runs
out, and the map still doesn't load. It has not been tested with the X11 driver
yet, so it may not be specific to Wayland.

Avoid the Map module for now. To hide it from the module bar, right-click the
module names (Library, Develop, Map…) and untick Map. If Lightroom freezes
there, use `start.sh` option `k` to stop the wine session.

---

## What works

For contrast — verified working under the tested environment:

- Installing Lightroom Classic from the standalone `Set-up.exe` or from the
  Creative Cloud desktop app.
- Launching into the Library module.
- The Develop module and all manual edits (tone, color, hand-painted masks,
  crop, etc).
- **AI masking** — Select Subject / Select Sky / Select Objects, on the CPU
  path (with `install-ai-masking.sh`, #1).
- The **filled colour histogram** with GPU acceleration on (with the patched
  `d2d1.dll`, #2).
- The Import window (with the `ScreenDepth=32` fix above, #8).
- Export and Copy Settings dialogs (with the repaint proxy, #6; no Export
  freeze, #6b).
- GPU acceleration (real D3D12 via vkd3d-proton; Preferences > Performance
  detects the GPU).
