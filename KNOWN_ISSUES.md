# Known Issues

Limitations and rough edges of Adobe **Lightroom Classic** under Wine, as of
wine 11.12 staging + DXVK 2.7.1 + vkd3d-proton 3.0.0 on Intel Iris Xe (Arch /
GNOME). None of these block the core workflow — install, launch, the Develop
module, manual edits, and GPU acceleration all work. The rough edges are around
AI features, the histogram, HDR, a couple of dialogs (Copy Settings / Export)
with a wine repaint bug, and log noise.

---

## 1. AI Masking does not work (object / subject / background detect, AI Denoise)

**Symptom:** triggering an AI mask (select subject, select sky/background,
object detection) or AI Denoise produces nothing; the CameraRaw log ends with
`*** Error: ML model not loaded ***`.

**Root cause — named, and it is NOT a wine deficiency.** We rule-ruled this out
exhaustively (observability only, no reverse-engineering):

- **The ML platform works under wine.** A purpose-built probe that loaded
  Adobe's *own* `onnxruntime.dll` (v1.23.0) under wine + vkd3d-proton via the
  ORT C API confirmed: `CreateEnv`, session options,
  `AppendExecutionProvider_CPU` and `AppendExecutionProvider_DML` all succeed,
  the provider list includes `Dml` and `CPU`, and creating a session from a
  hand-built minimal `.onnx` **succeeds on both DML and CPU**. So
  onnxruntime + DirectML-on-vkd3d-proton + the crypto stack are all functional
  under wine.
- **Crypto is fine.** A `bcrypt` trace shows `BCryptGenerateSymmetricKey` /
  `BCryptCreateHash` succeeding; the only unimplemented calls are trivial and
  irrelevant. Decryption primitives work.
- **The models are present and valid on disk** (42 non-empty `.data` files under
  `Resources/ModelZoo/*/winml/`, md5s matching `Index.dat`). The
  `CameraRaw/ModelZoo/CloudDownload` misses are just LR checking for cloud
  updates and falling back to local — normal.

**Where it actually fails:** Adobe's masking models are encrypted
`secured_file` blobs (high-entropy `.data`, no ONNX magic). The failure is
inside Adobe's proprietary **WFML decrypt-then-load** step — *before* inference
ever reaches onnxruntime — and is completely silent (Adobe overrides the ORT
logger; nothing in wine stderr or LR logs). Pinpointing further would mean
reverse-engineering Adobe's model encryption / content protection. **We
declined to do that. This is a definitive stop point — not a wine bug.**

> Note: spoofing the GPU as AMD (`LR_GPU_SPOOF=1`, GUIDE §7) flips LR's
> `Masking AI inference running on CPU: Intel parts` decision onto the
> GPU/DirectML path, but masking *still* fails at this same encrypted-model
> wall — and the spoof blanks the histogram (see #2). So the spoof is off by
> default.

---

## 2. Color histogram is "buggy" when GPU acceleration is on

**Symptom:** with GPU acceleration enabled (Preferences > Performance), the
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

**Workaround:** turn GPU acceleration **off** in Preferences > Performance — the
histogram then renders in full color, at the cost of slower editing. But, you can
keep GPU on (for speed) and accept the fill-less histogram.

> The Intel→AMD GPU spoof (`LR_GPU_SPOOF=1`) makes this *worse* — it blanks the
> histogram entirely — which is one reason the spoof is off by default.

> Spoof was using to trying to load ML for masking on the GPU, since intel gpu is know to be blacklisted by adobe...
---

## 3. HDR is not available

If your display panel is HDR-capable, but HDR editing in LrC needs native `winewayland.drv` **plus**
compositor HDR. On this GNOME / Mutter + wine 11.9 combination, the native
Wayland driver crashes LrC (`nodrv_CreateWindow` "explorer process failed to
start" + a page fault), so the default `LR_DRIVER=x11` path is used — and X11 /
Xwayland can't pass the monitor EDID / HDR through. Net: no HDR.

The blank-colorimetry log lines you may see are cosmetic for SDR work (Lightroom
uses sRGB / ICC color management). The launcher silences them by default.

---

## 4. Cosmetic log noise (silenced by the launcher)

`run-lightroom-classic.sh` suppresses these by default; they're all harmless and
listed here so you know what they are if you turn logging back on:

- **`RoGetActivationFactory ... Failed to find library`** for WinRT runtimeclasses
  wine doesn't implement (`Windows.Media.Core.MediaSource`,
  `Windows.Storage.Streams.InMemoryRandomAccessStream`, etc). Used for
  video/tutorial playback paths; LR falls back fine. (We even built a real
  working `InMemoryRandomAccessStream` factory to prove this error is not the
  cause of AI masking failing — it isn't.)
- **Adobe-internal CLSID "class not registered"** (`e26b366d-…` and similar).
- **EDID / colorimetry / "Failed to parse display metadata"** from DXVK — wine
  has no monitor EDID in the registry on the X11 path (see #3).
- **UI "unknown msg 06xx"** from common controls (header/listview/trackbar/
  progress).

---

## 5. wine missing export: `KERNEL32.dll.UnregisterApplicationRecoveryCallback`

Wine ships `RegisterApplicationRecoveryCallback` and
`ApplicationRecoveryFinished` but not `UnregisterApplicationRecoveryCallback`.
If LrC hits it, the process can abort on teardown. In practice this is mainly
seen *after* a crashed native-Wayland attempt (`LR_DRIVER=wayland`), which can
leave a stale wineserver in mixed driver state. Clear it before relaunching:

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

---

## What works

For contrast — verified working under the tested environment:

- Installing Lightroom Classic from the standalone `Set-up.exe`.
- Launching into the Library module.
- The Develop module and all manual edits (tone, color, hand-painted masks,
  crop, etc).
- The Import window (with the `ScreenDepth=32` fix above).
- Export and Copy Settings dialogs (with the repaint proxy, #6).
- GPU acceleration (real D3D12 via vkd3d-proton; Preferences > Performance
  detects the GPU).
