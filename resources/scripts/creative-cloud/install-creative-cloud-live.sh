#!/usr/bin/env bash
# install-creative-cloud-live.sh — install the Adobe Creative Cloud desktop app
# from Adobe's ONLINE bootstrapper (Creative_Cloud_Set-Up.exe), not the bundled
# offline ACCCx*.zip.
#
# WHY this exists (vs resources/scripts/creative-cloud/install-creative-cloud.sh):
#   The offline ACCCx*.zip we ship is a back-version of the CC desktop app. When
#   it runs, it installs the old core but then demands a *self-update* before it
#   will install the CoreSync component — and CoreSync provides CoreSync.exe AND
#   CCXProcess.exe, the processes that render the Home / Apps / Files / Fonts
#   panels. Under wine that self-update sits behind a "click Update Now" blue bar
#   that itself needs a panel applet to render → catch-22 → the panels stay blank
#   ("Unable to launch CoreSync Process. No version of core sync is installed.";
#   endless "OnProcessPingMiss" / "launchProcess CoreSync.exe Failed").
#
#   The ONLINE bootstrapper downloads the *current* CC desktop, which ships
#   CoreSync in the base install — so the panels work without the broken
#   self-update. This is the route to use when run-creative-cloud.sh shows a
#   window but the panels never load.
#
# Prereqs:
#   1. resources/scripts/wine/setup.sh has been run (wineprefix/ exists and is configured).
#   2. The online bootstrapper is at resources/installers/Creative_Cloud_Set-Up*.exe
#      (a few MB). Download it from:
#        https://creativecloud.adobe.com/apps/download/creative-cloud
#      and drop it in resources/installers/. (Adobe names it Creative_Cloud_Set-Up.exe.)
#
# What it does (mirrors install-creative-cloud.sh):
#   1. Ensures Microsoft Edge WebView2 is installed (the installer UI needs it).
#   2. Runs the bootstrapper in two phases with a clean wine-session restart
#      between them (sign-in winver, then install winver) — same flicker / OS
#      -check workaround the offline route uses.
#   3. Disables the AdobeGrowthSDK copies + HDUWP.dll that crash under wine.
#   4. Clears the installer's wine session so run-creative-cloud.sh starts clean.
#
# After this, run resources/scripts/creative-cloud/run-creative-cloud.sh — the Apps panel should render
# (CoreSync now installed), then Apps > Install Lightroom Classic.

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

# Cap the DXVK present rate (mild anti-flicker throttle). Override DXVK_FRAME_RATE.
export DXVK_FRAME_RATE="${DXVK_FRAME_RATE:-60}"

# Software-render the Edge WebView2 that draws the installer/login UI (GPU present
# through DXVK's dummy swapchain flickers on wine/Xwayland). --disable-gpu = CPU
# render, no flicker. Does NOT fix the invisible login cursor (separate wine
# pointer bug) — at sign-in just click the email field, type, Tab, type, Enter.
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---disable-gpu}"

# ---------------------------------------------------------------------------
# 0. The prefix must already be set up
# ---------------------------------------------------------------------------
if [ ! -f "$PREFIX/system.reg" ]; then
  echo "ERROR: wineprefix not initialized at $PREFIX"
  echo "Run resources/scripts/wine/setup.sh first."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Locate the online bootstrapper
# ---------------------------------------------------------------------------
# Adobe's download is named "Creative_Cloud_Set-Up.exe"; accept a few spellings
# and an optional version/suffix. First arg overrides the path.
SETUP="${1:-}"
if [ -z "$SETUP" ]; then
  SETUP=$(ls "$REPO_DIR"/resources/installers/Creative_Cloud_Set-Up*.exe \
             "$REPO_DIR"/resources/installers/"Creative Cloud Set-Up"*.exe \
             "$REPO_DIR"/resources/installers/Creative_Cloud_Set-Up.exe \
             "$REPO_DIR"/resources/installers/Creative_Cloud_Set*.exe 2>/dev/null | head -n1 || true)
fi
if [ -z "$SETUP" ] || [ ! -f "$SETUP" ]; then
  echo "ERROR: online bootstrapper not found."
  echo "Download 'Creative_Cloud_Set-Up.exe' from"
  echo "  https://creativecloud.adobe.com/apps/download/creative-cloud"
  echo "and drop it in $REPO_DIR/resources/installers/  (or pass its path as an argument)."
  exit 1
fi
echo "==> Using online bootstrapper: $(basename "$SETUP")"

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
# 3. Launch the bootstrapper — TWO PHASES with a clean restart
# ---------------------------------------------------------------------------
# Same constraint as the offline route: the WebView2 sign-in page flickers under
# win11 but is stable under win7; the install/download phase rejects win7's OS
# version. Switching winver *while* the installer runs deadlocks it
# ("RtlpWaitForCriticalSection ... retrying (60 sec)"), so we restart the wine
# session cleanly between phases. Override with CC_LOGIN_WINVER/CC_INSTALL_WINVER.
CC_LOGIN_WINVER="${CC_LOGIN_WINVER:-win7}"
CC_INSTALL_WINVER="${CC_INSTALL_WINVER:-win10}"

echo "==> Phase 1 (sign in): Windows version $CC_LOGIN_WINVER — no flicker on the login page"
"$REPO_DIR/resources/scripts/wine/set-winver.sh" "$CC_LOGIN_WINVER" >/dev/null 2>&1 || true
echo "==> Launching the bootstrapper (window on DISPLAY=$DISPLAY) — sign in with your Adobe ID."
LD_PRELOAD= $WINE "$SETUP" &
echo
echo "    ----------------------------------------------------------------"
echo "    >>> Once you are SIGNED IN, press Enter here. The wine session"
echo "        restarts under $CC_INSTALL_WINVER so the download/install passes"
echo "        the OS check, then it fetches the CURRENT CC desktop (CoreSync"
echo "        bundled)."
echo "    ----------------------------------------------------------------"
read -r _ < /dev/tty || true

echo "==> Killing the wine session for a clean version switch (wineserver -k)"
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
pkill -9 -f "$PREFIX" 2>/dev/null || true
sleep 3

echo "==> Phase 2 (download + install): Windows version $CC_INSTALL_WINVER"
"$REPO_DIR/resources/scripts/wine/set-winver.sh" "$CC_INSTALL_WINVER" >/dev/null 2>&1 || true
echo "==> Relaunching the bootstrapper — it resumes with your saved login and"
echo "    downloads + installs the current Creative Cloud desktop app."
echo "    This is a network download — give it time."
LD_PRELOAD= $WINE "$SETUP" || true

# ---------------------------------------------------------------------------
# 4. Disable AdobeGrowthSDK + HDUWP (post-install) — same crashers as the
#    offline route.
# ---------------------------------------------------------------------------
# AdobeGrowthSDK.dll / growthsdk.node call kernel32.SetThreadpoolTimerEx, which
# wine 11.x doesn't implement → "Unhandled exception: unimplemented function
# KERNEL32.dll.SetThreadpoolTimerEx" aborts the Experience node.exe (the panel
# host) and the panels die. The ONLINE installer drops these at version-specific
# paths in BOTH "Program Files" and "Program Files (x86)", so don't hardcode
# paths — find every copy and disable it. (Re-enable by renaming .disabled back.)
echo "==> Disabling all AdobeGrowthSDK copies (crash node.exe via SetThreadpoolTimerEx)"
find "$PREFIX/drive_c" \( -iname 'AdobeGrowthSDK.dll' -o -iname 'growthsdk.node' \) \
     ! -name '*.disabled' 2>/dev/null | while read -r f; do
  mv "$f" "$f.disabled" && echo "    disabled: ${f#"$PREFIX/drive_c/"}"
done
cd "$PREFIX/drive_c"

echo "==> Disabling HDUWP.dll (UWP installer module; aborts on wine)"
HDUWP="Program Files (x86)/Common Files/Adobe/Adobe Desktop Common/HDBox/HDUWP.dll"
if [ -f "$HDUWP" ] && [ ! -f "$HDUWP.disabled" ]; then
  mv "$HDUWP" "$HDUWP.disabled"
  echo "    disabled: $HDUWP"
fi

echo "==> Clearing the installer's wine session (wineserver -k)"
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true

echo
echo "==> install-creative-cloud-live.sh done."
echo "    Launch the Creative Cloud app with:  resources/scripts/creative-cloud/run-creative-cloud.sh"
echo "    The Apps panel should now render (CoreSync installed)."
echo "    Then Apps > Install Lightroom Classic; afterwards run:"
echo "      resources/scripts/lightroom/install-lightroom-classic-fixes.sh"
