# Known Issues

Limitations and rough edges of Adobe **Lightroom Classic** under Wine, as of
wine 11.9 staging + DXVK 2.7.1 + vkd3d-proton 3.0.0 on Intel Iris Xe (Arch /
GNOME). None of these block the core workflow — install, launch, the Develop
module, manual edits, and GPU acceleration all work. The rough edges are around
AI features, the histogram, HDR, and log noise.

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
Develop/Library histogram renders but its RGB channels are not display well. The
**photo image colors themselves are correct** — only the histogram widget is
affected.

**Cause:** DXVK 2.7.1 (latest, tested) doesn't render that widget's additive-blend RGB
channels. It's a DXVK limitation, not a Lightroom or wine bug, and it's not
version-fixable here (already on the latest DXVK release).

**Workaround:** turn GPU acceleration **off** in Preferences > Performance — the
histogram then renders in full color, at the cost of slower editing. But, you can
keep GPU on (for speed) and accept the "monochrome" histogram.

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

## What works

For contrast — verified working under the tested environment:

- Installing Lightroom Classic from the standalone `Set-up.exe`.
- Launching into the Library module.
- The Develop module and all manual edits (tone, color, hand-painted masks,
  crop, etc).
- GPU acceleration (real D3D12 via vkd3d-proton; Preferences > Performance
  detects the GPU).
