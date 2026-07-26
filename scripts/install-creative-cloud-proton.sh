#!/usr/bin/env bash
# install-creative-cloud-proton.sh — install the Creative Cloud desktop app via
# GE-Proton, then install Lightroom Classic from its Apps panel.
#
# GE-Proton variant of install-creative-cloud.sh. GE-Proton's tuned DXVK usually
# renders the CC/CEF UI without the flicker that forced the win7/win10 dance on
# system wine, so this runs straight through under win10 (passes Adobe's OS
# check). If you still see flicker, set PROTON_WINVER=win7 for the run and flip
# to win10 only to click Install (scripts/proton-common.sh: pset_winver).
#
# Reuses the installers in installers/ (ACCCx*.zip, MicrosoftEdgeWebview2Setup).

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proton-common.sh"

proton_preflight || exit 1
export DXVK_CONFIG_FILE="$PFX/dxvk.conf"

# Installers live in resources/installers/ (preferred) or installers/.
INST_DIR=""
for d in "$REPO_DIR/resources/installers" "$REPO_DIR/installers"; do
  [ -d "$d" ] && { INST_DIR="$d"; break; }
done
[ -n "$INST_DIR" ] || { echo "ERROR: no resources/installers or installers dir."; exit 1; }
echo "==> [proton] installers dir: $INST_DIR"

# 1. Pick the installer. PREFER the online bootstrapper Creative_Cloud_Set-Up*.exe
#    (it bundles CoreSync, so the CC Apps/Home panels render — the offline ACCCx
#    zip defers CoreSync and the panels come up blank). Fall back to ACCCx.
SETUP=$(ls "$INST_DIR"/Creative_Cloud_Set-Up*.exe 2>/dev/null | head -n1 || true)
if [ -n "$SETUP" ]; then
  echo "==> [proton] using ONLINE Creative Cloud installer: $(basename "$SETUP")"
else
  ZIP=$(ls "$INST_DIR"/ACCCx*.zip 2>/dev/null | head -n1 || true)
  [ -z "$ZIP" ] && { echo "ERROR: no Creative_Cloud_Set-Up*.exe or ACCCx*.zip in $INST_DIR."; exit 1; }
  UNZIP_DIR="${ZIP%.zip}"
  [ -d "$UNZIP_DIR" ] || { echo "==> Unzipping $(basename "$ZIP")"; unzip -q "$ZIP" -d "$UNZIP_DIR"; }
  SETUP="$UNZIP_DIR/Set-up.exe"
  [ -f "$SETUP" ] || { echo "ERROR: $SETUP not found."; exit 1; }
  echo "==> [proton] using OFFLINE ACCCx installer: $SETUP"
fi

# 2. Microsoft Edge WebView2 (Adobe installer engine needs it).
WV2="$INST_DIR/MicrosoftEdgeWebview2Setup.exe"
if [ ! -f "$WV2" ]; then
  echo "==> Downloading MicrosoftEdgeWebview2Setup.exe"
  curl -L -o "$WV2" "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
fi
echo "==> [proton] Installing WebView2 runtime"
urun "$WV2" /silent /install || true

# 3. Windows version for the install (win10 = passes OS check, no Mica flicker).
pset_winver "${PROTON_WINVER:-win10}"

# 4. Launch the CC installer.
echo "==> [proton] Launching Adobe Creative Cloud installer"
echo "    Sign in with your Adobe ID; then Apps panel > Install Lightroom Classic."
urun "$SETUP" || true

# 5. Post-install fixes: disable AdobeGrowthSDK + HDUWP (same wine-version issues).
DRIVE_C=$(find "$PFX" -maxdepth 3 -type d -name drive_c 2>/dev/null | head -n1)
if [ -n "$DRIVE_C" ]; then
  cd "$DRIVE_C"
  for f in \
    "Program Files/Common Files/Adobe/Adobe Desktop Common/GrowthSDK/AdobeGrowthSDK.dll" \
    "Program Files (x86)/Common Files/Adobe/Adobe Desktop Common/HDBox/HDUWP.dll"; do
    [ -f "$f" ] && [ ! -f "$f.disabled" ] && { mv "$f" "$f.disabled"; echo "    disabled: $f"; }
  done
fi

echo
echo "==> install-creative-cloud-proton.sh done."
echo "    Run CC:  scripts/run-creative-cloud-proton.sh"
echo "    After Lightroom Classic installs: scripts/install-lightroom-classic-fixes.sh"
echo "      (point it at the Proton prefix:  WINEPREFIX=\"$PFX\" scripts/install-lightroom-classic-fixes.sh)"
