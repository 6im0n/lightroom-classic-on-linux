#!/usr/bin/env bash
# disable-cc-crashers.sh — rename the Creative Cloud modules that crash under wine.
#
#   AdobeGrowthSDK.dll / growthsdk.node call kernel32.SetThreadpoolTimerEx, which
#   wine 11.x doesn't implement → "unimplemented function
#   KERNEL32.dll.SetThreadpoolTimerEx" aborts the Experience node.exe (the panel
#   host), so the window sits on "Initializing Creative Cloud..." forever.
#   CC drops them at version-specific paths in both Program Files trees and
#   reinstalls them when it updates, so find every copy each time.
#
#   HDUWP.dll is the HD installer's UWP module. It imports
#   kernel32.PackageFamilyNameFromId, an aborting stub in wine 11.x, so Adobe
#   Installer.exe dies when it loads it during an app install (e.g. Lightroom
#   Classic from the Apps panel). Classic is plain Win32 and doesn't need it.
#
# Idempotent; run by the CC install scripts and before every
# run-creative-cloud.sh launch. Re-enable a file by renaming .disabled back.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="${WINEPREFIX:-$REPO_DIR/wineprefix}"
C="$PREFIX/drive_c"

find "$C" \( -iname 'AdobeGrowthSDK.dll' -o -iname 'growthsdk.node' \) \
     ! -name '*.disabled' 2>/dev/null | while read -r f; do
  mv -f "$f" "$f.disabled" && echo "==> disabled: ${f#"$C/"}"
done

HDUWP="$C/Program Files (x86)/Common Files/Adobe/Adobe Desktop Common/HDBox/HDUWP.dll"
if [ -f "$HDUWP" ]; then
  mv -f "$HDUWP" "$HDUWP.disabled" && echo "==> disabled: ${HDUWP#"$C/"}"
fi
