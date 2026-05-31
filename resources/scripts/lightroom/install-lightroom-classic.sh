#!/usr/bin/env bash
# install-lightroom-classic.sh — run Adobe Lightroom *Classic*'s standalone
# installer under wine.
#
# Unlike Lightroom CC (installed from the Creative Cloud apps panel), this
# uses the standalone Set-up.exe / setup.exe offline installer you already
# have. It reuses the SAME wineprefix that resources/scripts/wine/setup.sh built, so all the
# d2d1 / mfplat / stub-DLL fixes are already in place.
#
# Prereqs:
#   1. resources/scripts/wine/setup.sh has been run (wineprefix/ exists and is configured).
#   2. The Lightroom Classic installer is at resources/installers/lightroom/Set-up.exe
#      (or pass its path as the first argument).
#
# What it does:
#   1. Verifies the prefix exists.
#   2. Forces the prefix to report Windows 11. The standalone Adobe HD
#      installer does its OWN OS-version check (the CC desktop app doesn't),
#      and rejects anything below Win10 with "you are running an incompatible
#      os version" -> "System Requirements check failed". A fresh wine prefix
#      can report Win7 (build 7601), which fails this check.
#   3. Ensures Microsoft Edge WebView2 is installed (the Adobe installer
#      engine needs it).
#   4. Launches the installer with winegstreamer DISABLED. The installer's
#      embedded UI (Gecko/xul) tries to init audio playback, which goes
#      l3codecx.ax -> winegstreamer -> mfplat.MFCreateAudioMediaType. Wine
#      11.x stubs that function, so the call aborts and kills the whole
#      installer mid-run. Disabling winegstreamer skips the media path; the
#      installer UI doesn't need audio.
#
# After install, run resources/scripts/lightroom/install-lightroom-classic-fixes.sh for the
# post-install fixups (AdobeGrowthSDK disable, lowercase symlinks).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="$REPO_DIR/wineprefix"
WINE=${WINE:-wine}
DISPLAY=${DISPLAY:-:0}

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export DXVK_CONFIG_FILE="$PREFIX/dxvk.conf"
export WINEDEBUG=${WINEDEBUG:--all,err+all,fixme-all}
export DISPLAY

# ---------------------------------------------------------------------------
# 0. Locate the installer
# ---------------------------------------------------------------------------
SETUP="${1:-$REPO_DIR/resources/installers/lightroom/Set-up.exe}"
if [ ! -f "$SETUP" ]; then
  echo "ERROR: installer not found at: $SETUP"
  echo
  echo "Put Lightroom Classic's installer at resources/installers/lightroom/Set-up.exe,"
  echo "or pass its path:  ./resources/scripts/lightroom/install-lightroom-classic.sh /path/to/Set-up.exe"
  echo
  echo "Keep the installer's sibling files/folders (products/, resources/, etc)"
  echo "next to Set-up.exe — the Adobe installer needs them."
  exit 1
fi
SETUP=$(cd "$(dirname "$SETUP")" && pwd)/$(basename "$SETUP")

# ---------------------------------------------------------------------------
# 1. The prefix must already be set up
# ---------------------------------------------------------------------------
if [ ! -f "$PREFIX/system.reg" ]; then
  echo "ERROR: wineprefix not initialized at $PREFIX"
  echo "Run resources/scripts/wine/setup.sh first."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1b. Force Windows 11 (the standalone installer's OS check rejects < Win10)
# ---------------------------------------------------------------------------
BUILD=$($WINE reg QUERY "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion" \
  /v CurrentBuildNumber 2>/dev/null | awk '/CurrentBuildNumber/ {print $NF}')
if [ "${BUILD:-0}" -lt 22000 ] 2>/dev/null; then
  echo "==> Prefix reports build ${BUILD:-unknown}; setting Windows version to 11"
  ${WINETRICKS:-winetricks} -q win11
else
  echo "==> Windows version already >= 11 (build $BUILD)"
fi

# ---------------------------------------------------------------------------
# 2. Microsoft Edge WebView2 (Adobe installer engine needs it)
# ---------------------------------------------------------------------------
WV2_INSTALLER="$REPO_DIR/resources/installers/MicrosoftEdgeWebview2Setup.exe"
if [ ! -d "$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView" ]; then
  if [ ! -f "$WV2_INSTALLER" ]; then
    echo "==> Downloading MicrosoftEdgeWebview2Setup.exe"
    curl -L -o "$WV2_INSTALLER" \
      "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
  fi
  echo "==> Installing WebView2 runtime"
  $WINE "$WV2_INSTALLER" /silent /install || true
else
  echo "==> WebView2 already installed"
fi

# ---------------------------------------------------------------------------
# 3. Launch the Lightroom Classic installer
# ---------------------------------------------------------------------------
echo "==> Launching Lightroom Classic installer:"
echo "    $SETUP"
echo "    Window should appear on DISPLAY=$DISPLAY"
echo "    Sign in / accept prompts in the installer UI; wait for it to finish."
echo

# winegstreamer disabled: see header note (4). Without this the installer's
# embedded UI aborts on mfplat.MFCreateAudioMediaType.
LD_PRELOAD= WINEDLLOVERRIDES="winegstreamer=${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}" \
  $WINE "$SETUP" || true

echo
echo "==> install-lightroom-classic.sh done (installer exited)."
echo "    If 'Program Files/Adobe/Adobe Lightroom Classic/' now exists, run:"
echo "      resources/scripts/lightroom/install-lightroom-classic-fixes.sh"
