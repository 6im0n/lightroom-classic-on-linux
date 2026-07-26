#!/usr/bin/env bash
# proton-common.sh — shared environment + helpers for the GE-Proton variant.
#
# Source this from the *-proton.sh scripts. It runs everything through
# umu-launcher (umu-run), which drives a standalone GE-Proton build (no Steam):
# GE-Proton bundles tuned DXVK + vkd3d-proton + media-foundation (mfplat) + fsync,
# which fixes the codec/mfplat errors and tends to be faster + more stable than
# system wine for the Adobe CC/CEF UI.
#
# Prereqs:
#   * umu-launcher installed (Arch AUR: `umu-launcher`; provides `umu-run`).
#   * GE-Proton: set PROTONPATH to an extracted GE-Proton dir, OR leave it as the
#     default "GE-Proton" and umu-run auto-downloads the latest release for you.
#
# Everything lives in a SEPARATE prefix (wineprefix-proton/) so the system-wine
# setup is untouched. Use the matching *-proton.sh scripts (or ./start.sh once
# the Proton route is wired in).

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PFX="${WINEPREFIX:-$REPO_DIR/wineprefix-proton}"
export PFX

# GE-Proton build umu should use. "GE-Proton" = let umu fetch/keep latest.
PROTONPATH="${PROTONPATH:-GE-Proton}"
export PROTONPATH
# Non-Steam app: GAMEID 0. STORE none avoids store-specific fixes.
export GAMEID="${GAMEID:-0}"
export STORE="${STORE:-none}"
# Quiet DXVK/vkd3d device dumps; keep them with UMU_LOG=1 / DXVK_LOG_LEVEL=info.
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"
export VKD3D_DEBUG="${VKD3D_DEBUG:-none}"
# Persist the DXVK shader cache so launches warm up across runs.
export DXVK_STATE_CACHE_PATH="${DXVK_STATE_CACHE_PATH:-$PFX/dxvk-cache}"
# Perf: fsync on (GE default), async shader compile (no stutter/stall).
export PROTON_NO_FSYNC="${PROTON_NO_FSYNC:-0}"
export DXVK_ASYNC="${DXVK_ASYNC:-1}"

proton_preflight() {
  if ! command -v umu-run >/dev/null 2>&1; then
    echo "ERROR: umu-run not found. Install umu-launcher first:"
    echo "       Arch:  yay -S umu-launcher   (or paru -S umu-launcher)"
    echo "       then re-run. GE-Proton itself is auto-downloaded by umu-run."
    return 1
  fi
  mkdir -p "$PFX" "$DXVK_STATE_CACHE_PATH" 2>/dev/null || true
  return 0
}

# urun <args...>  — run a program/command inside the GE-Proton environment.
#   urun "$SETUP"              -> run a Windows .exe (unix or C:\ path)
#   urun wine reg add ...      -> run a wine tool
#   urun winetricks <verb>     -> winetricks against the Proton prefix
urun() {
  WINEPREFIX="$PFX" GAMEID="$GAMEID" STORE="$STORE" PROTONPATH="$PROTONPATH" \
    umu-run "$@"
}

# uwine <args...> — convenience for wine tool commands (reg, wineboot, …).
uwine() { urun wine "$@"; }

# pset_winver win7|win10|win11 — set the reported Windows version via direct
# registry writes (fast; no winetricks/wineboot, so it's safe mid-install).
pset_winver() {
  local ver="${1:-}" cv build pn major minor
  case "$ver" in
    win7)  cv=6.1;  build=7601;  pn="Microsoft Windows 7";  major=6;  minor=1 ;;
    win10) cv=10.0; build=19045; pn="Microsoft Windows 10"; major=10; minor=0 ;;
    win11) cv=10.0; build=22000; pn="Microsoft Windows 11"; major=10; minor=0 ;;
    *) echo "pset_winver: need win7|win10|win11"; return 2 ;;
  esac
  local CV='HKLM\Software\Microsoft\Windows NT\CurrentVersion'
  uwine reg add 'HKCU\Software\Wine' /v Version /t REG_SZ /d "$ver" /f  >/dev/null 2>&1 || true
  uwine reg add "$CV" /v CurrentVersion     /t REG_SZ /d "$cv"    /f >/dev/null 2>&1 || true
  uwine reg add "$CV" /v CurrentBuild       /t REG_SZ /d "$build" /f >/dev/null 2>&1 || true
  uwine reg add "$CV" /v CurrentBuildNumber /t REG_SZ /d "$build" /f >/dev/null 2>&1 || true
  uwine reg add "$CV" /v ProductName        /t REG_SZ /d "$pn"    /f >/dev/null 2>&1 || true
  if [ "$ver" = win7 ]; then
    uwine reg delete "$CV" /v CurrentMajorVersionNumber /f >/dev/null 2>&1 || true
    uwine reg delete "$CV" /v CurrentMinorVersionNumber /f >/dev/null 2>&1 || true
  else
    uwine reg add "$CV" /v CurrentMajorVersionNumber /t REG_DWORD /d "$major" /f >/dev/null 2>&1 || true
    uwine reg add "$CV" /v CurrentMinorVersionNumber /t REG_DWORD /d "$minor" /f >/dev/null 2>&1 || true
  fi
  echo "==> [proton] Windows version = $ver (build $build)"
}
