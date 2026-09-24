#!/usr/bin/env bash
# install-dcomp-webview2.sh — install the prebuilt WebView2 dcomp.dll into the
# prefix, scoped to msedgewebview2.exe only.
#
# WHY: wine-staging 11.11+'s dcomp makes Edge WebView2 (the Creative Cloud
# installer / app sign-in pages) crash-loop its gpu-process: each restart maps
# another ~300 MB copy of msedge.dll and RAM runs away until the machine
# stalls. This dcomp.dll is built from wine-staging 11.10's patchset (without
# the IDCompositionDevice3 change) by build-dcomp-webview2.sh; see
# resources/patches/wine/dcomp-webview2.patch for the full story.
#
# The DLL goes into system32 and is set to native via
# HKCU\Software\Wine\AppDefaults\msedgewebview2.exe\DllOverrides, so every
# other program keeps loading wine's builtin dcomp. Idempotent. Re-run after
# a wine upgrade (wineboot rewrites system32 placeholders).
#
# Same key also pins d3d11/dxgi/d3d10core to wine's builtin (wined3d) for
# WebView2: under DXVK 3.1 its gpu-process leaks GPU buffers (~400 MB/s of
# shared memory on an Intel iGPU, 16 GB within a minute). With wined3d RAM
# stays flat. Lightroom and everything else keep DXVK.
#
# Finally WebView2 alone reports Windows 7 (AppDefaults\msedgewebview2.exe
# Version=win7): on win8+ Chromium's window presentation flickers constantly
# under wine; as win7 it doesn't. Adobe's bootstrapper keeps the prefix's
# win10, which it needs (2.14.0.82+ refuses win7 with error 21).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="${WINEPREFIX:-$REPO_DIR/wineprefix}"
WINE=${WINE:-wine}
DLL="$REPO_DIR/resources/stubs/binaries/dcomp-webview2.dll"
SYSTEM32="$PREFIX/drive_c/windows/system32"

if [ ! -f "$DLL" ]; then
  echo "ERROR: $DLL not found — build it with resources/scripts/wine/build-dcomp-webview2.sh" >&2
  exit 1
fi
if [ ! -d "$SYSTEM32" ]; then
  echo "ERROR: Wine prefix system32 not found: $SYSTEM32 (run setup first)" >&2
  exit 1
fi

cp -f "$DLL" "$SYSTEM32/.dcomp.dll.new"
mv -f "$SYSTEM32/.dcomp.dll.new" "$SYSTEM32/dcomp.dll"
echo "==> Installed $SYSTEM32/dcomp.dll (WebView2 dcomp)"

WINEDEBUG=-all WINEPREFIX="$PREFIX" "$WINE" reg ADD \
  'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe\DllOverrides' \
  /v dcomp /t REG_SZ /d native /f >/dev/null
echo "==> Set dcomp=native for msedgewebview2.exe only"

for dll in d3d11 dxgi d3d10core; do
  WINEDEBUG=-all WINEPREFIX="$PREFIX" "$WINE" reg ADD \
    'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe\DllOverrides' \
    /v "$dll" /t REG_SZ /d builtin /f >/dev/null
done
echo "==> Set d3d11/dxgi/d3d10core=builtin (wined3d) for msedgewebview2.exe only"

WINEDEBUG=-all WINEPREFIX="$PREFIX" "$WINE" reg ADD \
  'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe' \
  /v Version /t REG_SZ /d win7 /f >/dev/null
echo "==> Set Windows version win7 for msedgewebview2.exe only (no flicker)"
