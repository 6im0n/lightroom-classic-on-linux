#!/usr/bin/env bash
# install-vkd3d-proton.sh — install vkd3d-proton (real D3D12) into the prefix.
#
# WHY: wine's builtin d3d12.dll reports a fake placeholder adapter ("Intel HD
# Graphics 4000"), so Lightroom Classic's CameraRaw GPU manager enumerates 0
# GPUs -> GPU acceleration off -> AI masking (GPU/DirectML) can't run. Dropping
# vkd3d-proton's real D3D12 (Vulkan-backed, like DXVK) makes LR enumerate and
# qualify the real GPU. vkd3d-proton runs fine on system wine + system Vulkan;
# no Proton-wine swap or reinstall needed.
#
# Source order:
#   1. winetricks -q vkd3d            (portable, downloads official vkd3d-proton)
#   2. a Proton / GE-Proton runner's lib/wine/vkd3d-proton/x86_64-windows/
#      (set VKD3D_SRC=/path/to/that/dir to use it instead)

set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="$REPO_DIR/wineprefix"
SYS32="$PREFIX/drive_c/windows/system32"
WINE=${WINE:-wine}
export WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG=${WINEDEBUG:--all}

if [ ! -f "$PREFIX/system.reg" ]; then
  echo "ERROR: prefix not found at $PREFIX. Run resources/scripts/wine/setup.sh first."; exit 1
fi

install_from_dir() {
  local src="$1"
  for d in d3d12.dll d3d12core.dll; do
    if [ -f "$src/$d" ]; then
      [ -f "$SYS32/$d" ] && [ ! -f "$SYS32/$d.wine-builtin-bak" ] && cp -n "$SYS32/$d" "$SYS32/$d.wine-builtin-bak"
      cp -v "$src/$d" "$SYS32/$d"
    fi
  done
}

if [ -n "${VKD3D_SRC:-}" ] && [ -d "$VKD3D_SRC" ]; then
  echo "==> Installing vkd3d-proton from $VKD3D_SRC"
  install_from_dir "$VKD3D_SRC"
else
  # Try a GE-Proton runner if present (Bottles/Steam), else winetricks.
  GE_DIR=$(ls -d "$HOME"/.var/app/com.usebottles.bottles/data/bottles/runners/*/files/lib/wine/vkd3d-proton/x86_64-windows 2>/dev/null | tail -n1 || true)
  if [ -n "$GE_DIR" ]; then
    echo "==> Installing vkd3d-proton from GE-Proton runner: $GE_DIR"
    install_from_dir "$GE_DIR"
  else
    echo "==> Installing vkd3d-proton via winetricks"
    "${WINETRICKS:-winetricks}" -q vkd3d
  fi
fi

echo "==> Setting d3d12 / d3d12core DLL overrides to native"
$WINE reg ADD 'HKCU\Software\Wine\DllOverrides' /v d3d12     /t REG_SZ /d native /f >/dev/null 2>&1 || true
$WINE reg ADD 'HKCU\Software\Wine\DllOverrides' /v d3d12core /t REG_SZ /d native /f >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Intel iGPU spoof: Lightroom Classic routes its AI Masking inference to CPU
# whenever it detects an Intel GPU ("Masking AI inference running on CPU: Intel
# parts"), and that CPU path fails to load the model under wine. Presenting the
# adapter as a generic AMD discrete GPU flips LR onto the GPU/DirectML path and
# also clears some Develop rendering glitches. The spoof only changes the
# reported vendor/name; vkd3d-proton still runs on the real Vulkan device.
# Set INMEM_NO_SPOOF=1 to skip.
# OPTIONAL Intel->AMD spoof (OFF by default). Set LR_GPU_SPOOF=1 to enable.
#
# Rationale + WARNING: spoofing the adapter as AMD makes LR route AI Masking to
# the GPU/DirectML path instead of "CPU: Intel parts". BUT (a) AI Masking still
# fails afterwards because Adobe's models are encrypted and the decrypt-load is
# the real wall (not the GPU), and (b) the spoof makes LR take an AMD-specific
# GPU render path that BLANKS the Develop/Library histogram under DXVK. So for
# normal use, leave it OFF: real-Intel + GPU on gives correct photo colours and
# a (monochrome) histogram. Only enable if you specifically want to experiment
# with the GPU masking path and don't care about the histogram.
DXVK_CONF="$PREFIX/dxvk.conf"
if [ "${LR_GPU_SPOOF:-0}" = "1" ] && [ -f "$DXVK_CONF" ] && ! grep -q '^dxgi.customVendorId' "$DXVK_CONF"; then
  echo "==> LR_GPU_SPOOF=1: spoofing adapter as AMD in dxvk.conf"
  cat >> "$DXVK_CONF" <<'EOF'

# Intel iGPU -> present as AMD (opt-in via LR_GPU_SPOOF). NOTE: blanks the
# histogram under DXVK and does NOT make AI Masking work (encrypted-model wall).
dxgi.customVendorId = 1002
dxgi.customDeviceId = 73bf
dxgi.customDeviceDesc = "AMD Radeon RX 6800 XT"
EOF
fi

echo
echo "==> vkd3d-proton installed. Verify with a D3D12 probe or just launch LR:"
echo "    LR Preferences > Performance should now detect your GPU."
