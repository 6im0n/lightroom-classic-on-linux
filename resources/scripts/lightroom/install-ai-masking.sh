#!/usr/bin/env bash
# install-ai-masking.sh — enable Lightroom Classic's on-device AI masking
# (Select Subject / Select Sky / Select Objects) under wine.
#
# Adobe's masking runs ONNX models through WinML (microsoft.ai.machinelearning
# + onnxruntime). Two things block it on wine, both fixed here:
#
#   1. WinML loads each model through a chain of Windows.Storage.Streams WinRT
#      runtimeclasses that wine only half-implements, so the model never
#      reaches onnxruntime ("ML model not loaded" / a 0xc0000005 inside
#      microsoft.ai.machinelearning.dll). We supply them ourselves with a small
#      in-process WinRT DLL (resources/stubs/sources/winrt_inmemstream.c)
#      providing:
#        - Windows.Storage.Streams.InMemoryRandomAccessStream
#        - Windows.Storage.Streams.DataWriter
#        - Windows.Storage.Streams.RandomAccessStreamReference
#        - IAsyncInfo on its async results (WinML's await needs get_Status;
#          missing it = the null-deref crash)
#      and rewinds the stream in OpenReadAsync so WinML reads the whole model.
#
#   2. onnxruntime sizes its CPU inference arena to TOTAL system RAM. On a
#      16 GB box it logs "CPU memory (15.305 GB)" and tries to grab everything
#      -> OOM / desktop freeze. fakeram.so (LD_PRELOAD) caps the RAM wine
#      reports (sysinfo + /proc/meminfo) so the arena is bounded. The launcher
#      sets this up; this script just builds it.
#
# Both binaries ship prebuilt in resources/stubs/binaries/. They are rebuilt
# only when missing or older than their source, or with MASKING_REBUILD=1;
# that needs x86_64-w64-mingw32-gcc (mingw-w64) and gcc. Without a compiler
# the shipped binaries are installed as they are.
# Idempotent — safe to re-run.
#
# NOTE: masking uses the CPU path (it detects an Intel iGPU and runs on CPU).
# It is INCOMPATIBLE with the AMD GPU-spoof in dxvk.conf: with the spoof,
# masking takes a DirectML/vkd3d GPU path that hangs the integrated GPU. This
# script removes the spoof. (GPU acceleration for normal Develop editing still
# works without the spoof; only the masking-on-fake-AMD path is dropped.)

set -uo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="$REPO_DIR/wineprefix"
SRC="$REPO_DIR/resources/stubs/sources"
BIN="$REPO_DIR/resources/stubs/binaries"
SYS32="$PREFIX/drive_c/windows/system32"
WINE="${WINE:-wine}"

echo "==> Lightroom Classic AI-masking enabler"

# --- checks -------------------------------------------------------------------
[ -d "$PREFIX" ] || { echo "  MISSING: wineprefix at $PREFIX (run setup first)"; exit 1; }
mkdir -p "$BIN"
MASKING_REBUILD="${MASKING_REBUILD:-0}"

# needs_build OUT SRC : rebuild when forced, when OUT is missing, or when SRC is
# newer than OUT. Compared in whole seconds with 5 s of slack: a git clone
# writes binaries/ a few milliseconds before sources/.
needs_build() {
  [ "$MASKING_REBUILD" = 1 ] || [ ! -f "$1" ] ||
    [ "$(stat -c %Y "$2")" -gt $(( $(stat -c %Y "$1") + 5 )) ]
}

# no_compiler OUT CC : explain what happens when OUT should be built but CC is
# missing. Keeps a shipped binary; aborts when there is none.
no_compiler() {
  if [ -f "$1" ]; then
    echo "  $2 not found; using the shipped $(basename "$1")"
  else
    echo "  MISSING: $(basename "$1") and no $2 to build it (install mingw-w64 / gcc)"
    exit 1
  fi
}

# --- 1. the WinRT stream DLL (PE / mingw) ------------------------------------
WINRT="$BIN/winrt_inmemstream.dll"
if ! needs_build "$WINRT" "$SRC/winrt_inmemstream.c"; then
  echo "==> winrt_inmemstream.dll is up to date"
elif ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  no_compiler "$WINRT" x86_64-w64-mingw32-gcc
else
  echo "==> Building winrt_inmemstream.dll"
  # Fedora's mingw64-headers vendors a stale windows.storage.streams.idl that's
  # missing IInputStream, IContentTypeProvider, InputStreamOptions, and the
  # IAsyncOperationWithProgress<IBuffer*,UINT32> generic instantiation this stub
  # needs. wine-staging-devel from WineHQ ships a complete copy (widl-generated
  # for the installed wine runtime itself); use it if present. On Fedora the
  # headers can also be unpacked from the WineHQ RPM with rpm2cpio (GUIDE §6b).
  WINE_INC="${WINE_INC:-/opt/wine-staging/include/wine/windows}"
  WINE_INCFLAG=()
  [ -d "$WINE_INC" ] && WINE_INCFLAG=(-I"$WINE_INC")
  if ! x86_64-w64-mingw32-gcc -shared -O2 -Wno-incompatible-pointer-types \
        "${WINE_INCFLAG[@]}" \
        -o "$WINRT" "$SRC/winrt_inmemstream.c" \
        -lruntimeobject -lole32 -luuid -lwindowsapp; then
    echo "  BUILD FAILED (winrt_inmemstream.dll)"; exit 1
  fi
fi
cp -f "$WINRT" "$SYS32/winrt_inmemstream.dll"
echo "    installed -> system32/winrt_inmemstream.dll"

# --- 2. the fake-RAM shim (ELF / gcc) ----------------------------------------
FAKERAM="$BIN/fakeram.so"
if ! needs_build "$FAKERAM" "$SRC/fakeram.c"; then
  echo "==> fakeram.so is up to date"
elif ! command -v gcc >/dev/null 2>&1; then
  no_compiler "$FAKERAM" gcc
else
  echo "==> Building fakeram.so"
  if ! gcc -shared -fPIC -O2 -o "$FAKERAM" "$SRC/fakeram.c" -ldl; then
    echo "  BUILD FAILED (fakeram.so)"; exit 1
  fi
  echo "    built -> resources/stubs/binaries/fakeram.so"
fi

# --- 3. register the three WinRT runtimeclasses -> our DLL --------------------
# NOTE: these entries do not survive a wine upgrade. The prefix update that runs
# after one rewrites HKLM\...\WindowsRuntime\ActivatableClassId and points
# DataWriter / RandomAccessStreamReference back at wine's own builtins (wine
# 11.12 ships both in wintypes.dll / windows.storage.dll), which leaves WinML on
# a mixed stack. run-lightroom-classic.sh re-asserts them at launch; re-running
# this script fixes them too.
echo "==> Registering WinRT ActivatableClassId entries"
reg_class() {
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" reg add \
    "HKLM\\Software\\Microsoft\\WindowsRuntime\\ActivatableClassId\\$1" \
    /v DllPath /t REG_SZ /d 'C:\windows\system32\winrt_inmemstream.dll' /f \
    >/dev/null 2>&1 && echo "    $1"
}
reg_class "Windows.Storage.Streams.InMemoryRandomAccessStream"
reg_class "Windows.Storage.Streams.DataWriter"
reg_class "Windows.Storage.Streams.RandomAccessStreamReference"

# --- 4. drop the AMD GPU spoof (incompatible with CPU masking) ---------------
if [ -f "$PREFIX/dxvk.conf" ] && grep -qi customVendorId "$PREFIX/dxvk.conf"; then
  echo "==> Removing AMD GPU spoof from dxvk.conf (incompatible with masking)"
  grep -viE "customVendorId|customDeviceId|customDeviceDesc|AMD (GPU )?spoof|improves Develop|masking to a|Spoofing the|which both works|NAME string|RandomAccessStreamReference points|masking stays disarmed" \
    "$PREFIX/dxvk.conf" > "$PREFIX/dxvk.conf.tmp" && mv "$PREFIX/dxvk.conf.tmp" "$PREFIX/dxvk.conf"
fi

echo
echo "==> Done. AI masking is enabled."
echo "    Launch with: resources/scripts/lightroom/run-lightroom-classic.sh"
echo "    (the launcher auto-loads fakeram.so; tune with FAKERAM_GB=<N>)"
echo "    Try: Develop > Masking > Select Subject / Select Sky."
