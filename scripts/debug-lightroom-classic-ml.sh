#!/usr/bin/env bash
# debug-lightroom-classic-ml.sh — trace Lightroom Classic's AI-masking ML path.
#
# Launches LR with a WINEDEBUG that captures DLL loads + WinRT activation +
# exceptions, you trigger a mask (Develop > Masking > Select Sky), close LR, and
# it prints a summary: which ML/stream DLLs loaded, any missing WinRT class
# ("Failed to find library"), access violations (c0000005), and the CameraRaw
# WML result. Log: /tmp/lrc-ml-debug.log
#
# Usage:
#   scripts/debug-lightroom-classic-ml.sh
#     -> launch, do Select Sky in LR, then CLOSE LR; summary prints.

set -uo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREFIX="$REPO_DIR/wineprefix"
WINE=${WINE:-wine}
LOG=/tmp/lrc-ml-debug.log
LR='C:\Program Files\Adobe\Adobe Lightroom Classic\Lightroom.exe'
CRLOG="$PREFIX/drive_c/users/$USER/AppData/Roaming/Adobe/CameraRaw/Logs/Adobe Photoshop Lightroom Classic Log Latest v0.txt"

# Channels: loaddll (DLL load order), seh (exceptions/c0000005), combase+ole
# (WinRT/COM activation misses), module (failed imports). FORCE it — ignore any
# WINEDEBUG already exported in the shell (that was hiding these channels).
# Override deliberately with ML_WINEDEBUG=... if you really want to.
export WINEDEBUG="${ML_WINEDEBUG:-+loaddll,+seh,+combase,+ole,+module,fixme-all}"
export WINEPREFIX="$PREFIX" WINEARCH=win64
export DXVK_CONFIG_FILE="$PREFIX/dxvk.conf" DXVK_LOG_LEVEL=none VKD3D_DEBUG=none
export DISPLAY="${DISPLAY:-:0}"

echo "==> Killing any running Lightroom for a clean trace"
ps -eo pid,args | grep -i "Lightroom.exe" | grep -v grep | awk '{print $1}' | xargs -r kill -9 2>/dev/null
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
sleep 2

echo "==> Launching Lightroom (logging to $LOG)"
echo "    In LR: Develop > Masking > Select Sky (or Subject). Wait ~8s. Then CLOSE LR."
echo
LD_PRELOAD= "$WINE" "$LR" > "$LOG" 2>&1 || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "================ ML TRACE SUMMARY ================"
echo "-- ML / stream DLLs loaded (in order) --"
grep -aiE "loaddll.*Loaded" "$LOG" | grep -aiE "onnxruntime|directml|machinelearning|wfml|wichita|opencv_ml|shcore_winrt|shcore\.dll|windows\.storage|wintypes" \
  | sed -E 's/.*Loaded L"([^"]+)".*: ?([a-z]+)?.*/\2  \1/' | head -40
echo
echo "-- Missing WinRT classes (Failed to find library) --"
grep -aoE 'Failed to find library for L"[^"]+"' "$LOG" | sort | uniq -c || echo "  none"
echo
echo "-- Failed module imports --"
grep -aiE "err:module|import_dll.*not found" "$LOG" | grep -aivE "GetPointer" | sed -E 's/^[0-9a-f]+://' | sort -u | head || echo "  none"
echo
echo "-- Access violations / unhandled exceptions --"
grep -aiE "c0000005|Unhandled exception|NtRaiseException" "$LOG" | sed -E 's/^[0-9a-f]+://' | sort -u | head || echo "  none"
echo
echo "-- CameraRaw WML result --"
grep -inE "WML_LoadFromData|WML API failed|ML model|persistent model|Masking AI" "$CRLOG" 2>/dev/null | tail -6
echo "================================================="
echo "Full log: $LOG"
