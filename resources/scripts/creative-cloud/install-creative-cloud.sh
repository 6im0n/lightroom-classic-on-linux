#!/usr/bin/env bash
# install-creative-cloud.sh — install the Adobe Creative Cloud desktop app
# under wine, then install Lightroom *Classic* from its Apps panel.
#
# This is the ALTERNATIVE to resources/scripts/lightroom/install-lightroom-classic.sh. Instead of
# the standalone offline Set-up.exe, it installs the Creative Cloud desktop app
# (from the offline ACCCx*.zip), which you then sign into and use to install
# Lightroom Classic (or any other CC app) into the prefix. Both routes share
# the SAME wineprefix that resources/scripts/wine/setup.sh built, so the d2d1 / mfplat /
# hnetcfg fixes are already in place either way.
#
# Prereqs:
#   1. resources/scripts/wine/setup.sh has been run (wineprefix/ exists and is configured).
#   2. The offline CC installer ACCCx*.zip is in resources/installers/. Download it from
#      https://helpx.adobe.com/download-install/apps/download-install-apps/creative-cloud-apps/download-creative-cloud-desktop-app-using-direct-links.html
#
# What it does:
#   1. Unzips resources/installers/ACCCx*.zip into resources/installers/ACCCx*/ (idempotent).
#   2. Silently installs Microsoft Edge WebView2 if not already present
#      (the Adobe installer engine needs it).
#   3. Launches Set-up.exe (the CC bootstrap). You sign in interactively and
#      install Lightroom Classic from the Apps panel.
#   4. After CC is installed, disables the AdobeGrowthSDK.dll copies that ship
#      with the CC desktop app (they call kernel32.SetThreadpoolTimerEx, which
#      wine 11.x doesn't implement, and crash node.exe under wine).
#
# The launch is a plain root-window wine launch — do NOT add a wine virtual
# desktop or a HiDPI LogPixels override (both broke the CC/CEF window: black
# borders, or no window at all under Wayland/Mutter). The only thing that
# actually blocked this route was the OS-version check, now handled by
# setup.sh setting the prefix to win11. For a too-small UI on HiDPI, adjust
# DPI once via winecfg (Graphics tab).
#
# NOTE: unlike the standalone installer, the CC desktop app skips its own
# OS-version check, so no winetricks win11 step is needed here. If installing
# Lightroom Classic from the CC Apps panel fails with an "incompatible os
# version" error, run `WINEPREFIX="$PWD/wineprefix" winetricks -q win11` and
# retry the in-CC install.
#
# After Lightroom Classic is installed via the CC UI, run
# resources/scripts/lightroom/install-lightroom-classic-fixes.sh for the post-install fixups.

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

# Software-render the Edge WebView2 (Chromium) that draws the installer/login UI.
# By default WebView2 renders on the GPU and presents through DXVK's dummy DXGI
# composition swapchain, which on wine/Xwayland fights the compositor and makes
# the installer window flicker badly. --disable-gpu drops WebView2 to CPU
# rendering: no swapchain, no flicker. WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS is
# read by the WebView2 runtime. Override/clear it if you want GPU rendering back.
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---disable-gpu}"

# NOTE on the invisible cursor at sign-in: separately, the login page's embedded
# WebView2 child window doesn't get pointer events under wine/Xwayland, so the
# cursor is invisible over the login box (it returns once the native CC UI takes
# over after sign-in; --disable-gpu above does NOT fix the cursor, and native
# winewayland crashes the Adobe apps on GNOME here). The cursor still WORKS —
# click the email field, type, Tab to password, type, Enter. One-time sign-in.

# ---------------------------------------------------------------------------
# 0. The prefix must already be set up
# ---------------------------------------------------------------------------
if [ ! -f "$PREFIX/system.reg" ]; then
  echo "ERROR: wineprefix not initialized at $PREFIX"
  echo "Run resources/scripts/wine/setup.sh first."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Unzip the offline CC installer
# ---------------------------------------------------------------------------
ZIP=$(ls "$REPO_DIR"/installers/ACCCx*.zip 2>/dev/null | head -n1 || true)
if [ -z "$ZIP" ]; then
  echo "ERROR: no resources/installers/ACCCx*.zip found."
  echo "Download it from https://creativecloud.adobe.com/apps/download/creative-cloud"
  echo "and drop it in $REPO_DIR/resources/installers/"
  exit 1
fi

UNZIP_DIR="${ZIP%.zip}"
if [ ! -d "$UNZIP_DIR" ]; then
  echo "==> Unzipping $(basename "$ZIP")"
  unzip -q "$ZIP" -d "$UNZIP_DIR"
fi

SETUP="$UNZIP_DIR/Set-up.exe"
if [ ! -f "$SETUP" ]; then
  echo "ERROR: $SETUP not found after unzipping. Wrong archive?"
  exit 1
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
# 3. Launch the Adobe Creative Cloud installer — TWO PHASES with a clean restart
# ---------------------------------------------------------------------------
# The Set-up.exe sign-in page (Edge WebView2) flickers under win11 but is stable
# under win7; the install phase rejects win7's OS version. We can't switch the
# version *while* Set-up.exe runs — that deadlocks it ("RtlpWaitForCriticalSection
# ... wait timed out ... retrying (60 sec)"). So instead:
#   Phase 1: run Set-up.exe under win7 → you sign in (no flicker).
#   --- kill the whole wine env (wineserver -k) for a clean version switch ---
#   Phase 2: relaunch Set-up.exe under win10 (passes the OS check, no win11
#            flicker) → it resumes with your saved login and installs CC.
# Plain root-window launch (no wine virtual desktop — fails to map under Mutter
# on Wayland; no HiDPI LogPixels override — gave the CC window black borders).
# Override versions with CC_LOGIN_WINVER / CC_INSTALL_WINVER.
CC_LOGIN_WINVER="${CC_LOGIN_WINVER:-win7}"
CC_INSTALL_WINVER="${CC_INSTALL_WINVER:-win10}"

echo "==> Phase 1 (sign in): Windows version $CC_LOGIN_WINVER — no flicker on the login page"
"$REPO_DIR/resources/scripts/wine/set-winver.sh" "$CC_LOGIN_WINVER" >/dev/null 2>&1 || true
echo "==> Launching Set-up.exe (window on DISPLAY=$DISPLAY) — sign in with your Adobe ID."
LD_PRELOAD= $WINE "$SETUP" &
echo
echo "    ----------------------------------------------------------------"
echo "    >>> Once you are SIGNED IN, press Enter here. The wine session"
echo "        restarts under $CC_INSTALL_WINVER so the install passes the OS check."
echo "    ----------------------------------------------------------------"
read -r _ < /dev/tty || true

echo "==> Killing the wine session for a clean version switch (wineserver -k)"
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
# make sure nothing Adobe is left holding the prefix
pkill -9 -f "$PREFIX" 2>/dev/null || true
sleep 3

echo "==> Phase 2 (install): Windows version $CC_INSTALL_WINVER"
"$REPO_DIR/resources/scripts/wine/set-winver.sh" "$CC_INSTALL_WINVER" >/dev/null 2>&1 || true
echo "==> Relaunching Set-up.exe — it resumes with your saved login."
echo "    Let it install the Creative Cloud app; then Apps panel > Install Lightroom Classic."
LD_PRELOAD= $WINE "$SETUP" || true

# ---------------------------------------------------------------------------
# 4. Disable AdobeGrowthSDK (post-install)
# ---------------------------------------------------------------------------
echo "==> Disabling AdobeGrowthSDK copies bundled with the CC desktop app"
cd "$PREFIX/drive_c"
for f in \
  "Program Files/Common Files/Adobe/Adobe Desktop Common/GrowthSDK/AdobeGrowthSDK.dll" \
  "Program Files/Adobe/Adobe Creative Cloud Experience/js/node_modules/@growthsdk/growthsdk/public/binaries/win.x64/Release/AdobeGrowthSDK.dll" \
  "Program Files/Adobe/Adobe Creative Cloud Experience/js/node_modules/@growthsdk/growthsdk/public/binaries/win.x64/Release/growthsdk.node"; do
  if [ -f "$f" ] && [ ! -f "$f.disabled" ]; then
    mv "$f" "$f.disabled"
    echo "    disabled: $f"
  fi
done

# HDUWP.dll is the HD installer's UWP/packaged-app module. It statically imports
# kernel32.PackageFamilyNameFromId, which wine 11.x only has as an aborting stub
# — so when Adobe Installer.exe loads HDUWP during an app install it dies with
# "Call ... to unimplemented function KERNEL32.dll.PackageFamilyNameFromId,
# aborting", and the Lightroom Classic install fails. LR Classic is a plain
# Win32 app, so the UWP module isn't needed: disabling it makes the installer
# skip that path and complete. (Re-enable by renaming the .disabled file back.)
echo "==> Disabling HDUWP.dll (UWP installer module; aborts on wine)"
HDUWP="Program Files (x86)/Common Files/Adobe/Adobe Desktop Common/HDBox/HDUWP.dll"
if [ -f "$HDUWP" ] && [ ! -f "$HDUWP.disabled" ]; then
  mv "$HDUWP" "$HDUWP.disabled"
  echo "    disabled: $HDUWP"
fi

# Clear the wine session left over by the installer. Adobe's background services
# (Adobe Desktop Service, AdobeIPCBroker, CoreSync, Creative Cloud Helper) keep
# running after Set-up.exe finishes; if they're left alive, the next time you
# launch the Creative Cloud app it just hands off to them and never shows its
# window. Killing the session here means resources/scripts/creative-cloud/run-creative-cloud.sh starts
# clean and the UI actually appears.
echo "==> Clearing the installer's wine session (wineserver -k)"
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true

echo
echo "==> install-creative-cloud.sh done."
echo "    Launch the Creative Cloud app with:  resources/scripts/creative-cloud/run-creative-cloud.sh"
echo "    Then click Apps > Install on Lightroom Classic."
echo "    After Lightroom Classic is installed, run:"
echo "      resources/scripts/lightroom/install-lightroom-classic-fixes.sh"
