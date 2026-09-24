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

# ---------------------------------------------------------------------------
# Clear the wine session before every launch.
#
# Lightroom.exe statically imports KERNEL32.UnregisterApplicationRecoveryCallback,
# which wine does not export. Wine wires an aborting stub into that import slot,
# so closing Lightroom kills the thread mid-shutdown:
#
#   wine: Call from ... to unimplemented function
#         KERNEL32.dll.UnregisterApplicationRecoveryCallback, aborting
#
# The window disappears but the process stays alive holding its locks, and the
# next launch then deadlocks against it:
#
#   err:sync:RtlpWaitForCriticalSection ... wait timed out in thread ..., blocked by ...
#
# Adobe's background services (Adobe Desktop Service, AdobeIPCBroker, CoreSync)
# linger the same way. So kill the prefix's wine session first — nothing on disk
# is touched, only running processes. Lightroom is single-instance anyway: a
# second copy deadlocks rather than opening a window.
#
# LR_KILL_STALE=0 skips this (e.g. to attach a debugger to a running instance).
# ---------------------------------------------------------------------------
LR_KILL_STALE="${LR_KILL_STALE:-1}"
if [ "$LR_KILL_STALE" != 0 ]; then
  if pgrep -f 'Lightroom\.exe' >/dev/null 2>&1; then
    echo "==> clearing the previous wine session (stale Lightroom teardown)"
  fi
  WINEPREFIX="$REPO_DIR/wineprefix" wineserver -k >/dev/null 2>&1 || true
  # wineserver -k returns before the processes are reaped; wait for them so the
  # new instance never races the old one's locks.
  _n=0
  while pgrep -f 'Lightroom\.exe' >/dev/null 2>&1 && [ "$_n" -lt 20 ]; do
    sleep 0.25
    _n=$((_n + 1))
  done
fi

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
# Opening the Import window aborts the whole process with an Xlib error:
#   X Error of failed request:  BadMatch (invalid parameter attributes)
#   Major opcode of failed request:  62 (X_CopyArea)
#
# Cause: on a Wayland session (Xwayland) the X server advertises a depth-24
# default visual *and* a depth-32 ARGB visual (wine logs "init_visuals default
# visual 23 class 4 argb 7c"). Wine composites parts of the UI through the ARGB
# visual, and X_CopyArea between drawables of different depth is a protocol
# error — which Xlib turns into an abort, killing Lightroom.
#
# Fix: pin wine's default visual to the depth-32 ARGB one, so every drawable
# has the same depth and the copy is legal (winex11 "ScreenDepth", see
# dlls/winex11.drv/x11drv_main.c). Written per-app so nothing else in the
# prefix is affected. LR_SCREEN_DEPTH=0 skips the write and uses whatever the
# prefix already has; 24 restores wine's default (and the crash).
#
# NOTE: WINE_X11_NO_MITSHM, which older revisions of this launcher exported,
# does nothing — wine has never implemented that variable (it was only ever
# requested, wine bug 43893), and there is no MIT-SHM string anywhere in the
# wine 11.12 binaries. It was removed rather than kept as a placebo.
LR_SCREEN_DEPTH="${LR_SCREEN_DEPTH:-32}"
if [ "$LR_SCREEN_DEPTH" != 0 ]; then
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "${WINE:-wine}" reg ADD \
    'HKCU\Software\Wine\AppDefaults\Lightroom.exe\X11 Driver' \
    /v ScreenDepth /t REG_SZ /d "$LR_SCREEN_DEPTH" /f >/dev/null 2>&1 || true
fi

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

# ---------------------------------------------------------------------------
# AI masking (Select Subject / Sky / Objects).
#
# Enabled by install-ai-masking.sh, which builds resources/stubs/binaries/fakeram.so and
# registers our WinRT stream classes. onnxruntime sizes its CPU inference arena
# to TOTAL RAM; on a 16 GB box it would try to grab everything and OOM/freeze.
# fakeram.so (LD_PRELOAD) caps the RAM wine reports so the arena is bounded.
#
# LR_MASKING = auto (default) | off
#   auto: load fakeram.so if present (masking installed); else no preload.
#   off:  never preload (masking will OOM-risk on low-RAM boxes).
# FAKERAM_GB: RAM cap (GB) reported to wine. Default ~60% of real RAM (leaves
#   headroom for LR + the desktop), floor 6. Override to taste.
# ---------------------------------------------------------------------------
LR_MASKING="${LR_MASKING:-auto}"
FAKERAM_SO="$REPO_DIR/resources/stubs/binaries/fakeram.so"
export LD_PRELOAD=
if [ "$LR_MASKING" != off ] && [ -f "$FAKERAM_SO" ]; then
  if [ -z "${FAKERAM_GB:-}" ]; then
    _totkb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    FAKERAM_GB=$(awk -v k="${_totkb:-0}" 'BEGIN{g=int(k/1024/1024*0.6); if(g<6)g=6; print g}')
  fi
  export LD_PRELOAD="$FAKERAM_SO" FAKERAM_GB
  echo "==> AI masking: fakeram.so loaded (RAM reported to wine capped at ${FAKERAM_GB}GB)"
fi

# ---------------------------------------------------------------------------
# Keep the WinRT stream classes pointed at our implementation.
#
# install-ai-masking.sh registers three Windows.Storage.Streams runtimeclasses
# against winrt_inmemstream.dll. A wine UPGRADE re-runs the prefix update, which
# rewrites HKLM\...\WindowsRuntime\ActivatableClassId wholesale and hands
# DataWriter / RandomAccessStreamReference back to wine's own builtins (wine
# 11.12 ships both), leaving WinML on a mixed stack. Re-assert ours whenever
# fewer than three entries still name our DLL. No-op if masking isn't installed.
# ---------------------------------------------------------------------------
WINRT_DLL="$PREFIX/drive_c/windows/system32/winrt_inmemstream.dll"
WINRT_REGISTERED=$(grep -c 'winrt_inmemstream\.dll' "$PREFIX/system.reg" 2>/dev/null || true)
if [ -f "$WINRT_DLL" ] && [ "${WINRT_REGISTERED:-0}" -lt 3 ]; then
  echo "==> Re-registering WinRT stream classes (a wine upgrade reset them)"
  for _cls in InMemoryRandomAccessStream DataWriter RandomAccessStreamReference; do
    WINEPREFIX="$PREFIX" WINEDEBUG=-all "${WINE:-wine}" reg add \
      "HKLM\\Software\\Microsoft\\WindowsRuntime\\ActivatableClassId\\Windows.Storage.Streams.$_cls" \
      /v DllPath /t REG_SZ /d 'C:\windows\system32\winrt_inmemstream.dll' /f >/dev/null 2>&1 || true
  done
fi

# The proxy version.dll (dialog-repaint fix) forwards to version_orig.dll, a
# copy of wine's builtin taken at install time. After a wine upgrade that copy
# is stale: warn so the fixes script can be re-run to refresh it.
_lr_dir="$PREFIX/drive_c/Program Files/Adobe/Adobe Lightroom Classic"
for _b in /usr/lib/wine/x86_64-windows/version.dll \
          "$(dirname "$(command -v "${WINE:-wine}" 2>/dev/null || echo /usr/bin/wine)")/../lib/wine/x86_64-windows/version.dll"; do
  [ -f "$_lr_dir/version_orig.dll" ] && [ -f "$_b" ] || continue
  cmp -s "$_lr_dir/version_orig.dll" "$_b" || echo \
    "==> note: version_orig.dll predates the installed wine — re-run install-lightroom-classic-fixes.sh"
  break
done

export DXVK_CONFIG_FILE="$PREFIX/dxvk.conf"
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG="$WINEDEBUG"

# Direct2D geometric-mask layers. The custom d2d1.dll contains a stencil-based
# PushLayer mask implementation that restores Lightroom's histogram fills.
# Enabled by default; disable it if a layered UI regression appears:
#   D2D_LAYER_MASK=0 resources/scripts/lightroom/run-lightroom-classic.sh
export D2D_LAYER_MASK="${D2D_LAYER_MASK:-1}"
if [ "$D2D_LAYER_MASK" != 0 ]; then
  echo "==> Direct2D geometric-mask layers: enabled"
fi

# Disable wine's discburning (IMAPI2) DLL. Lightroom's Export dialog enumerates
# CD/DVD burners through it on open, and wine's implementation blocks the main
# UI thread on an object that never signals -> Export freezes the whole app.
# install-lightroom-classic-fixes.sh also writes this to the prefix registry;
# we set it here too so a direct run is safe even before fixes are applied.
# Merge with any caller-supplied WINEDLLOVERRIDES.
export WINEDLLOVERRIDES="discburning=;${WINEDLLOVERRIDES:-}"

# ---------------------------------------------------------------------------
# Stop the prefix's wine session once Lightroom exits.
#
# Without this, wineserver, services.exe, rpcss, plugplay, lsass and the
# MicrosoftEdgeUpdate.exe that WebView2 spawns keep running after Lightroom
# closes, until the next launch clears them. Lightroom's own shutdown takes
# ~15 s after its window disappears; wine returns once it's done.
#
# The Creative Cloud app shares this prefix, so the session is left alone while
# "Creative Cloud.exe" is running. LR_KILL_ON_EXIT=0 always leaves it running.
# ---------------------------------------------------------------------------
LR_KILL_ON_EXIT="${LR_KILL_ON_EXIT:-1}"

set +e
if [ "$LR_VDESKTOP" = off ]; then
  "${WINE:-wine}" "$LR_EXE" "$@"
else
  echo "==> virtual desktop: $LR_VDESKTOP (fallback; raise LR_DPI if the UI looks tiny)"
  "${WINE:-wine}" explorer "/desktop=lrc,$LR_VDESKTOP" "$LR_EXE" "$@"
fi
rc=$?
set -e

if [ "$LR_KILL_ON_EXIT" = 0 ]; then
  exit "$rc"
fi
if pgrep -f 'Creative Cloud\.exe' >/dev/null 2>&1; then
  echo "==> Lightroom closed; Creative Cloud is still running, leaving the wine session up"
  exit "$rc"
fi
echo "==> Lightroom closed; stopping the wine session"
wineserver -k >/dev/null 2>&1 || true
timeout 20 wineserver -w >/dev/null 2>&1 || true
exit "$rc"

