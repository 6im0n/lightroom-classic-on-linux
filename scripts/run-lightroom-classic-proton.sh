#!/usr/bin/env bash
# run-lightroom-classic-proton.sh — launch Lightroom Classic via GE-Proton.
#
# GE-Proton variant of run-lightroom-classic.sh: same app, run through
# umu-launcher with GE-Proton's bundled DXVK/vkd3d/mfplat + fsync. Uses the
# separate wineprefix-proton/.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proton-common.sh"

proton_preflight || exit 1

export DXVK_CONFIG_FILE="$PFX/dxvk.conf"
LR='C:\Program Files\Adobe\Adobe Lightroom Classic\Lightroom.exe'

# HiDPI scale (same knob as the wine launcher). LR_DPI default 144; 96 disables.
LR_DPI="${LR_DPI:-144}"
uwine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$LR_DPI" /f >/dev/null 2>&1 || true

# PROTON_DESKTOP=WxH runs inside a wine virtual desktop. Use it if the mouse
# cursor is vertically offset (Xwayland + Mutter HiDPI scaling): in a virtual
# desktop wine draws its own cursor, so the offset goes away. e.g.
#   PROTON_DESKTOP=2304x1296 scripts/run-lightroom-classic-proton.sh
echo "==> [proton] launching Lightroom Classic"
# Note: can't `exec` urun — it's a shell function, not a binary.
if [ -n "${PROTON_DESKTOP:-}" ]; then
  urun wine explorer /desktop="lr,$PROTON_DESKTOP" "$LR" "$@"
else
  urun wine "$LR" "$@"
fi
