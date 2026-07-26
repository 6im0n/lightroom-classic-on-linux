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
#   4. Disable wine's discburning DLL. Lightroom's Export dialog probes CD/DVD
#      burners through it, and wine's implementation deadlocks the main UI
#      thread -> Export window freezes. Disabling it makes the probe fail fast.
#   5. Install the dialog-repaint fix (proxy version.dll). wine fails to erase
#      removed rows in Export's owner-data listview, while Adobe's subclassed
#      Copy Settings checkboxes drop WM_PAINT without validating or drawing.
#      The proxy hooks Lightroom's UI thread and, only inside modal dialogs,
#      fills+repaints the listview and subclasses the checkboxes to own their
#      WM_PAINT. Scoped to Lightroom.exe via a per-app DllOverride; see
#      resources/stubs/sources/fix_ghost.c for the full story. Re-running this
#      script also refreshes version_orig.dll after a wine upgrade.
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


# 4. Disable wine's discburning (IMAPI2 disc-burning) DLL. Lightroom's Export
#    dialog has a "Burn to disc" destination; on open it enumerates CD/DVD
#    burners through discburning, and wine's implementation blocks the main UI
#    thread on a sync object that never signals -> the whole Export window (and
#    app) freezes. We have no optical writer to burn to anyway, so disable the
#    DLL: the probe then fails fast and Export opens normally.
#    (Found via winedbg: main thread wait in discburning -> agkernel -> Export.)
echo "==> Disabling discburning (fixes the Export-window freeze)"
WINEPREFIX="$PREFIX" "${WINE:-wine}" reg add "HKCU\\Software\\Wine\\DllOverrides" \
  /v discburning /t REG_SZ /d "" /f >/dev/null 2>&1 \
  && echo "    HKCU\\Software\\Wine\\DllOverrides\\discburning = \"\" (disabled)" \
  || echo "    WARNING: could not write discburning override (run wine prefix setup first)"

# 5. Dialog ghosting / blank panels (Export preset tree, Copy Settings): wine
#    leaves removed rows painted in Export's owner-data listview, while the
#    Adobe-subclassed Copy Settings checkboxes drop WM_PAINT without drawing or
#    validating. Install the proxy version.dll (a UI-thread hook that, only
#    inside modal dialogs, fills+repaints the listview and subclasses the
#    checkboxes to own their WM_PAINT; see resources/stubs/sources/fix_ghost.c)
#    into Lightroom's app dir — first in the native DLL search path — and scope
#    the override to Lightroom.exe alone so the 32-bit Adobe helper processes
#    never load it.
#    version_orig.dll is re-copied from the *currently installed* wine on every
#    run, which is what refreshes it after a wine upgrade.
echo "==> Installing dialog-repaint fix (proxy version.dll, Lightroom.exe only)"
PROXY="$REPO_DIR/resources/stubs/binaries/version-proxy.dll"
BUILTIN_VERSION=""
for d in "$(dirname "$(command -v "${WINE:-wine}" || echo /usr/bin/wine)")/../lib/wine/x86_64-windows" \
         /usr/lib/wine/x86_64-windows; do
  if [ -f "$d/version.dll" ]; then BUILTIN_VERSION="$d/version.dll"; break; fi
done
if [ ! -f "$PROXY" ]; then
  echo "    WARNING: $PROXY not found — run resources/scripts/stubs/build-stubs.sh first; skipped"
elif [ -z "$BUILTIN_VERSION" ]; then
  echo "    WARNING: wine's builtin x86_64-windows/version.dll not found; skipped"
else
  cp -f "$PROXY" "$LR_DIR/version.dll"
  cp -f "$BUILTIN_VERSION" "$LR_DIR/version_orig.dll"
  echo "    installed version.dll (proxy) + version_orig.dll (wine builtin) in app dir"
  WINEPREFIX="$PREFIX" "${WINE:-wine}" reg add \
    "HKCU\\Software\\Wine\\AppDefaults\\Lightroom.exe\\DllOverrides" \
    /v version /t REG_SZ /d "native,builtin" /f >/dev/null 2>&1 \
    && echo "    AppDefaults\\Lightroom.exe\\DllOverrides\\version = native,builtin" \
    || echo "    WARNING: could not write the per-app version override"
fi

echo
echo "==> install-lightroom-classic-fixes.sh done."
echo "    Launch with: resources/scripts/lightroom/run-lightroom-classic.sh"
