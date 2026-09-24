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
#   2. Installs the WebView2 fixes (dcomp, wined3d, per-app win7, shared
#      msedge.dll) and runs the bootstrapper once under Windows 10: you sign in,
#      and it downloads + installs the current CC desktop in the same session.
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

# x11cursor.so: WebView2 (sign-in page) runs in another process than the Adobe
# window it sits in, so wine can't apply its cursor and the pointer vanishes.
# The shim gives top-level X windows a default arrow. See its source.
CURSOR_SHIM="$REPO_DIR/resources/stubs/binaries/x11cursor.so"
[ -f "$CURSOR_SHIM" ] || CURSOR_SHIM=""

# Cap the DXVK present rate (mild anti-flicker throttle). Override DXVK_FRAME_RATE.
export DXVK_FRAME_RATE="${DXVK_FRAME_RATE:-60}"

# Software-render the Edge WebView2 that draws the installer/login UI (GPU present
# through DXVK's dummy swapchain flickers on wine/Xwayland). --disable-gpu = CPU
# render, no flicker.
# NOTE: Adobe's current bootstrapper no longer picks this variable up (nor the
# WebView2 AdditionalBrowserArguments policy), so it is kept only for older
# builds. Flicker, GPU memory and the invisible pointer are now handled by
# install-dcomp-webview2.sh (per-app win7 + wined3d for msedgewebview2.exe) and
# the x11cursor.so preload below.
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
  echo "Adobe's site detects Linux and hides the Windows installer: switch your"
  echo "browser's user-agent to Windows first (e.g. the User-Agent Switcher extension"
  echo "  https://addons.mozilla.org/fr/firefox/addon/uaswitcher/ )."
  exit 1
fi
echo "==> Using online bootstrapper: $(basename "$SETUP")"

# ---------------------------------------------------------------------------
# 2. Microsoft Edge WebView2 (Adobe installer engine needs it)
# ---------------------------------------------------------------------------
# Uses the offline standalone installer when it's in resources/installers/,
# otherwise the online bootstrapper (see the helper).
"$REPO_DIR/resources/scripts/wine/install-webview2.sh"

# WebView2 (installer + sign-in pages) crash-loops its gpu-process on
# wine-staging 11.11+'s dcomp and eats all RAM. Give msedgewebview2.exe the
# pre-11.11 dcomp.dll (native for that exe only). See
# resources/patches/wine/dcomp-webview2.patch.
"$REPO_DIR/resources/scripts/wine/install-dcomp-webview2.sh"
# wine copies msedge.dll (~314 MB, 512-byte file alignment) into every WebView2
# process; page-align it so all processes share one copy (~3 GB saved).
"$REPO_DIR/resources/scripts/wine/realign-webview2.sh"
# CC 6.10 crashes at startup without a WinRT ToastNotificationManager (the
# installer launches it at the end), so register our stub before running it.
"$REPO_DIR/resources/scripts/creative-cloud/install-winrt-toast.sh"

# ---------------------------------------------------------------------------
# 3. Launch the bootstrapper — one session: sign in, then download + install
# ---------------------------------------------------------------------------
# This used to take two phases (sign in under win7 to stop the WebView2 page
# flickering, then restart the wine session under win10 for the OS check).
# install-dcomp-webview2.sh now gives msedgewebview2.exe its own win7 version,
# so the page doesn't flicker while the bootstrapper sees win10 the whole time.
# Bootstrapper 2.14.0.82+ refuses win7 at startup ("error 21 / Current OS is
# not supported"), so keep this at win10 or later. Override with CC_WINVER.
CC_WINVER="${CC_WINVER:-win10}"

echo "==> Windows version $CC_WINVER"
"$REPO_DIR/resources/scripts/wine/set-winver.sh" "$CC_WINVER" >/dev/null 2>&1 || true
echo "==> Launching the bootstrapper (window on DISPLAY=$DISPLAY)."
echo "    Sign in with your Adobe ID; it then downloads and installs the current"
echo "    Creative Cloud desktop app. This is a network download — give it time."
LD_PRELOAD="$CURSOR_SHIM" $WINE "$SETUP" || true

# ---------------------------------------------------------------------------
# 4. Disable AdobeGrowthSDK + HDUWP (post-install) — same crashers as the
#    offline route.
# ---------------------------------------------------------------------------
# GrowthSDK (SetThreadpoolTimerEx) + HDUWP (PackageFamilyNameFromId) abort
# under wine; see the helper. run-creative-cloud.sh repeats this on every
# launch, which matters when the bootstrapper is closed before this step runs.
"$REPO_DIR/resources/scripts/creative-cloud/disable-cc-crashers.sh"

echo "==> Clearing the installer's wine session (wineserver -k)"
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true

echo
echo "==> install-creative-cloud-live.sh done."
echo "    Launch the Creative Cloud app with:  resources/scripts/creative-cloud/run-creative-cloud.sh"
echo "    The Apps panel should now render (CoreSync installed)."
echo "    Then Apps > Install Lightroom Classic; afterwards run:"
echo "      resources/scripts/lightroom/install-lightroom-classic-fixes.sh"
