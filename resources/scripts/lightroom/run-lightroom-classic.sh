#!/usr/bin/env bash
# run-lightroom-classic.sh — launch Adobe Lightroom Classic under the prefix.
#
# Symlink or copy this anywhere (desktop file Exec=, panel launcher, etc).
# Single self-contained invocation.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

# Our own flags; everything else passes through to Lightroom.
#   --vdesktop[=WxH] : run inside a wine virtual desktop. This is a FALLBACK for
#                      the Import-module X_CopyArea crash. (lightroom tips)
#                      Sized to your screen via xrandr if no WxH is given.
#                      Trade-off: a wine virtual desktop doesn't get GNOME's
#                      per-window HiDPI scaling, so the UI can look tiny (raise
#                      the DPI to compensate). Off unless this flag is passed.
#   --dpi=N          : UI scale, as a wine LogPixels value (96 = 100%):
#                        96=100%  120=125%  144=150%  168=175%
#                       192=200%  240=250%  288=300%   (default 144 = 150%)
#                      Flag wins over the LR_DPI env var, which wins over 144.
LR_VDESKTOP="${LR_VDESKTOP:-off}"
_args=()
for _a in "$@"; do
  case "$_a" in
    --vdesktop)   LR_VDESKTOP=auto ;;
    --vdesktop=*) LR_VDESKTOP="${_a#*=}" ;;
    --dpi=*)      LR_DPI="${_a#*=}" ;;
    *)            _args+=("$_a") ;;
  esac
done
set -- "${_args[@]+"${_args[@]}"}"

# HiDPI: wine renders at 96 DPI (100%) by default, which looks tiny on
# high-density screens. Set LR_DPI to scale the whole UI:
#   96 = 100%   120 = 125%   144 = 150%   168 = 175%   192 = 200%
# Default 144. Export LR_DPI=96 to disable scaling, or any value you like.
# Applied to the shared prefix's HKCU\Control Panel\Desktop\LogPixels.
LR_DPI="${LR_DPI:-144}"
WINEPREFIX="$REPO_DIR/wineprefix" WINEDEBUG=-all \
  "${WINE:-wine}" reg ADD "HKCU\\Control Panel\\Desktop" \
    /v LogPixels /t REG_DWORD /d "$LR_DPI" /f >/dev/null 2>&1 || true

# WINEDEBUG: keep real errors, but silence the known-cosmetic channels that
# spam stderr and are harmless under wine:
#   combase  -> RoGetActivationFactory "Failed to find library" for WinRT
#               classes wine doesn't ship (Windows.Media.Core.MediaSource,
#               InMemoryRandomAccessStream, etc) — used for video/tutorial
#               playback; LR falls back fine.
#   ole      -> Adobe-internal CLSIDs (e26b366d…, 2853add3…) not registered.
#   header/listview/trackbar/progress -> "unknown msg 06xx" UI noise.
# Override by exporting your own WINEDEBUG.
WINEDEBUG="${WINEDEBUG:--all,err+all,fixme-all,err-combase,err-ole,err-header,err-listview,err-trackbar,err-progress}"

# DXVK + vkd3d-proton have their OWN loggers (not WINEDEBUG). These print the
# device-info dumps plus the harmless "readMonitorEdidFromKey / DXGI: Failed to
# parse display metadata" lines (wine has no monitor EDID in the registry, so
# DXVK uses blank HDR/colorimetry — irrelevant for SDR editing). Quiet them:
#   DXVK_LOG_LEVEL=none   VKD3D_DEBUG=none
# Override (e.g. DXVK_LOG_LEVEL=info) for debugging.
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"
export VKD3D_DEBUG="${VKD3D_DEBUG:-none}"

# ---------------------------------------------------------------------------
# Graphics driver: Wayland-native vs X11.
#
# On a Wayland session, wine's X11 driver runs through Xwayland, which does
# NOT pass the monitor EDID / HDR.
#
# LR_DRIVER = auto (default) | wayland | x11
#   auto: X11 (most compatible; works through Xwayland on Wayland sessions).
#   wayland: native winewayland.drv — passes EDID/HDR/colorimetry, BUT is
#     experimental: on GNOME/Mutter + wine 11.9 it can fail to start the
#     explorer/window driver and crash Lightroom. Only use if it works for you.
# Force a driver with LR_DRIVER=wayland or LR_DRIVER=x11.
# ---------------------------------------------------------------------------
LR_DRIVER="${LR_DRIVER:-auto}"
PREFIX="$REPO_DIR/wineprefix"
have_wayland_drv() { ls "$PREFIX"/drive_c/windows/system32/winewayland.drv >/dev/null 2>&1 \
    || ls /usr/lib/wine/*/winewayland.drv >/dev/null 2>&1; }

# Default auto -> X11. It works everywhere; native Wayland is opt-in because
# it's not yet reliable for LrC here.
if [ "$LR_DRIVER" = auto ]; then LR_DRIVER=x11; fi

if [ "$LR_DRIVER" = wayland ]; then
  echo "==> graphics driver: wayland (native)"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "${WINE:-wine}" reg ADD 'HKCU\Software\Wine\Drivers' \
    /v Graphics /t REG_SZ /d "wayland,x11" /f >/dev/null 2>&1 || true
  unset DISPLAY   # let wine pick Wayland via WAYLAND_DISPLAY
else
  echo "==> graphics driver: x11"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "${WINE:-wine}" reg ADD 'HKCU\Software\Wine\Drivers' \
    /v Graphics /t REG_SZ /d "x11" /f >/dev/null 2>&1 || true
  export DISPLAY="${DISPLAY:-:0}"
fi

# ---------------------------------------------------------------------------
# Import-module crash fix (default) + virtual-desktop fallback.
#
# On a Wayland session (Xwayland), some tips can crash the session
# with an Xlib abort:
#   X Error of failed request:  BadMatch (invalid parameter attributes)
#   Major opcode of failed request:  62 (X_CopyArea)
# default; override with WINE_X11_NO_MITSHM=0.
export WINE_X11_NO_MITSHM="${WINE_X11_NO_MITSHM:-0}"

# Fallback only: if the MIT-SHM fix isn't enough on your setup, --vdesktop runs
# Lightroom inside a wine virtual desktop (one root window wine owns, so there's
# no cross-depth copy to the real X server). Off unless --vdesktop is passed.
if [ "$LR_VDESKTOP" = auto ]; then
  LR_VDESKTOP=$(DISPLAY="${DISPLAY:-:0}" xrandr 2>/dev/null \
    | awk '/ connected/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+x[0-9]+\+/){split($i,a,"+"); print a[1]; exit}}')
  [ -z "$LR_VDESKTOP" ] && LR_VDESKTOP=$(DISPLAY="${DISPLAY:-:0}" xrandr 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | head -1)
  [ -z "$LR_VDESKTOP" ] && LR_VDESKTOP=1920x1080
fi

LR_EXE="C:\\Program Files\\Adobe\\Adobe Lightroom Classic\\Lightroom.exe"

export LD_PRELOAD=
export DXVK_CONFIG_FILE="$PREFIX/dxvk.conf"
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG="$WINEDEBUG"

if [ "$LR_VDESKTOP" = off ]; then
  exec "${WINE:-wine}" "$LR_EXE" "$@"
else
  echo "==> virtual desktop: $LR_VDESKTOP (fallback; raise LR_DPI if the UI looks tiny)"
  exec "${WINE:-wine}" explorer "/desktop=lrc,$LR_VDESKTOP" "$LR_EXE" "$@"
fi

