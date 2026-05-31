#!/usr/bin/env bash
# install-lightroom-classic-fixes.sh — post-install fixups for Lightroom
# *Classic* (the standalone-installer variant).
#
# Run this AFTER resources/scripts/lightroom/install-lightroom-classic.sh has installed Classic
# into the shared wineprefix. It applies the fixes that can only happen once
# the files exist on disk:
#
#   1. Rename Classic's bundled AdobeGrowthSDK.dll to .disabled. It calls
#      kernel32.SetThreadpoolTimerEx, which wine 11.x does not implement, so
#      loading it aborts the process. Classic has a fallback path without it.
#   2. Create lowercase symlinks for every .dll/.exe in the Classic install
#      dir. Classic's import tables list some DLLs in lowercase while Adobe
#      ships them MixedCase; wine's case-sensitive loader needs both names.
#   3. Block Adobe's dunamis in-app "feedback"/tips. On a Wayland session
#      (Xwayland), opening some modules triggers dunamis_feedback_show,
#      and wine's X11 driver then issues an X_CopyArea between mismatched-depth
#      drawables that Xwayland rejects (BadMatch, opcode 62), aborting
#      Lightroom. The tip is non-essential — we empty its campaign dir and lock
#      it read-only so the popup never renders (dunamis logs "feedback_show
#      failed" and carries on).
#
# KNOWN LIMITATION (not fixed here): Classic's AI object-detection / Remove
# tool activates the WinRT runtimeclasses
# Windows.Storage.Streams.InMemoryRandomAccessStream and
# Windows.Media.Core.MediaSource via RoGetActivationFactory. Wine 11.x does
# NOT implement these factories (registering them just turns the
# "Failed to find library" error into CLASS_E_CLASSNOTAVAILABLE 0x80040111).
# The log spam is harmless; the rest of Classic works, but the AI Remove /
# object-detection feature will not function until wine ships these classes.
#

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="$REPO_DIR/wineprefix"
LR_DIR="$PREFIX/drive_c/Program Files/Adobe/Adobe Lightroom Classic"

if [ ! -d "$LR_DIR" ]; then
  echo "ERROR: $LR_DIR not found."
  echo "Run resources/scripts/lightroom/install-lightroom-classic.sh and let the installer finish first."
  exit 1
fi

# 1. Disable Classic's bundled AdobeGrowthSDK.dll
SDK="$LR_DIR/AdobeGrowthSDK.dll"
if [ -f "$SDK" ] && [ ! -f "$SDK.disabled" ]; then
  echo "==> Disabling $SDK"
  mv "$SDK" "$SDK.disabled"
else
  echo "==> AdobeGrowthSDK.dll already disabled (or never existed)"
fi

# 2. Lowercase symlinks
echo "==> Creating lowercase symlinks in $LR_DIR"
cd "$LR_DIR"
shopt -s nullglob
made=0
for f in *.dll *.exe; do
  lower=$(echo "$f" | tr '[:upper:]' '[:lower:]')
  if [ "$f" != "$lower" ] && [ ! -e "$lower" ]; then
    ln -s "$f" "$lower"
    made=$((made+1))
  fi
done
echo "    created $made symlinks"

# 3. Block dunamis in-app feedback/tips (fixes the Develop > Masking
#    X_CopyArea crash on Xwayland). Empty the feedback campaign dir and lock it
#    read-only so dunamis can't (re)populate or render a tip. Done for every
#    real user profile in the prefix, and created pre-emptively if dunamis
#    hasn't run yet, so it survives a first launch.
echo "==> Blocking dunamis in-app feedback/tips (fixes the Masking X_CopyArea crash)"
for roaming in "$PREFIX"/drive_c/users/*/AppData/Roaming; do
  [ -d "$roaming" ] || continue
  fb="$roaming/com.adobe.dunamis/feedback"
  chmod -R u+w "$fb" 2>/dev/null || true   # unlock if a previous run locked it
  rm -rf "$fb" 2>/dev/null || true
  mkdir -p "$fb/v1"
  chmod -R a-w "$fb"                        # read-only: no campaign data, no tip
  echo "    locked read-only: ${fb#"$PREFIX/drive_c/"}"
done

echo
echo "==> install-lightroom-classic-fixes.sh done."
echo "    Launch with: resources/scripts/lightroom/run-lightroom-classic.sh"
