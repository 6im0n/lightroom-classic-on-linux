#!/usr/bin/env bash
# run-creative-cloud.sh — launch the Adobe Creative Cloud desktop app under the
# prefix (to install/update Lightroom Classic from its Apps panel, sign in, etc).
#
# Sibling of run-lightroom-classic.sh; same DPI / driver / log handling. The CC
# desktop app must already be installed (resources/scripts/creative-cloud/install-creative-cloud.sh).
# If its window drops to the background, this relaunches it.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="$REPO_DIR/wineprefix"
WINE=${WINE:-wine}
CC_EXE="C:\\Program Files\\Adobe\\Adobe Creative Cloud\\ACC\\Creative Cloud.exe"

if [ ! -f "$PREFIX/drive_c/Program Files/Adobe/Adobe Creative Cloud/ACC/Creative Cloud.exe" ]; then
  echo "ERROR: Creative Cloud desktop app not installed in $PREFIX"
  echo "Run resources/scripts/creative-cloud/install-creative-cloud.sh first."
  exit 1
fi

# Run the CC desktop UI under Windows 10 by default. win11 makes its CEF/Electron
# window flicker (DWM/Mica backdrop wine can't render); win10 has no Mica so it's
# stable, AND build 19045 still passes Adobe's OS check when you install
# Lightroom Classic from the Apps panel — so no version juggling is needed.
# (win7 also has no flicker but can deadlock Adobe's installer.) Override with
# CC_WINVER=win7|win11.
CC_WINVER="${CC_WINVER:-win10}"
echo "==> CC OS version: $CC_WINVER"
"$REPO_DIR/resources/scripts/wine/set-winver.sh" "$CC_WINVER" >/dev/null 2>&1 || true

# HiDPI: scale the UI (same knob/value Lightroom uses). CC_DPI overrides.
CC_DPI="${CC_DPI:-144}"
WINEPREFIX="$PREFIX" WINEDEBUG=-all \
  "$WINE" reg ADD "HKCU\\Control Panel\\Desktop" \
    /v LogPixels /t REG_DWORD /d "$CC_DPI" /f >/dev/null 2>&1 || true

# Silence the known-cosmetic wine channels (WinRT misses, unregistered CLSIDs,
# common-control "unknown msg" noise). err-mshtml drops the relentless
# "create_document_object Failed to init Gecko, CLASS_E_CLASSNOTAVAILABLE" spam:
# it's a *false alarm* — Gecko 2.47.4 is installed and works (wine's own iexplore
# renders HTML fine against this prefix); the failure is in a legacy Adobe IE/
# mshtml helper control, NOT the CEF (libcef) Apps panel that actually drives the
# UI, so it's harmless noise. Override by exporting WINEDEBUG.
WINEDEBUG="${WINEDEBUG:--all,err+all,fixme-all,err-combase,err-ole,err-header,err-listview,err-trackbar,err-progress,err-mshtml}"
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"
export VKD3D_DEBUG="${VKD3D_DEBUG:-none}"

# Persist the DXVK shader/pipeline state cache in a fixed, writable location.
# By default DXVK writes <app>.dxvk-cache to the app's CWD, which for the CC
# helpers ends up nowhere usable — so every launch recompiles pipelines cold,
# and the cold compile can stall the CEF GPU process into a crash. A stable
# cache path means once the pipelines are compiled, later launches are warm and
# don't stall, even after a full wineserver kill.
export DXVK_STATE_CACHE_PATH="${DXVK_STATE_CACHE_PATH:-$PREFIX/dxvk-cache}"
mkdir -p "$DXVK_STATE_CACHE_PATH" 2>/dev/null || true

# Cap the DXVK present rate (mild anti-flicker throttle). Override DXVK_FRAME_RATE.
export DXVK_FRAME_RATE="${DXVK_FRAME_RATE:-60}"

# Software-render the WebView2 (Chromium) sign-in/UI: its GPU present through
# DXVK's dummy composition swapchain fights the compositor on wine/Xwayland and
# flickers. --disable-gpu = CPU render, no swapchain, no flicker. (Does NOT fix
# the invisible login cursor — that's a separate wine pointer bug.)
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---disable-gpu}"

# If signed out, the Adobe login is an Edge WebView2 (Chromium) child window
# whose cursor is invisible under wine/Xwayland (a wine embedded-window pointer
# bug — not GPU; --disable-gpu doesn't help, winewayland crashes the app here).
# The cursor still works: click the email field, type, Tab, type, Enter. It's a
# one-time sign-in.

# Graphics driver: default X11 (works through Xwayland on Wayland sessions).
# CC_DRIVER=wayland to try native winewayland (experimental).
CC_DRIVER="${CC_DRIVER:-auto}"
if [ "$CC_DRIVER" = auto ]; then CC_DRIVER=x11; fi
if [ "$CC_DRIVER" = wayland ]; then
  echo "==> graphics driver: wayland (native)"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" reg ADD 'HKCU\Software\Wine\Drivers' \
    /v Graphics /t REG_SZ /d "wayland,x11" /f >/dev/null 2>&1 || true
  unset DISPLAY
else
  echo "==> graphics driver: x11"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" reg ADD 'HKCU\Software\Wine\Drivers' \
    /v Graphics /t REG_SZ /d "x11" /f >/dev/null 2>&1 || true
  export DISPLAY="${DISPLAY:-:0}"
fi

# Is a CC-owned window mapped? Title-independent: wmctrl -lp gives each window's
# owning PID; we match the process command line (the CC window often has an EMPTY
# title, so grepping the title misses it).
cc_window_up() {
  command -v wmctrl >/dev/null 2>&1 || return 1
  local id desk pid rest
  while read -r id desk pid rest; do
    [ -n "${pid:-}" ] && [ "$pid" != 0 ] || continue
    ps -p "$pid" -o args= 2>/dev/null | grep -qiE "Creative Cloud|Adobe" && return 0
  done < <(DISPLAY="${DISPLAY:-:0}" wmctrl -lp 2>/dev/null)
  return 1
}

# Always start clean. Adobe's background services (Desktop Service, CoreSync,
# IPCBroker) survive previous runs/crashes, and a fresh launch just hands off to
# them WITHOUT raising a window. Killing the wine session first guarantees a real
# fresh launch that shows the window. The DXVK shader cache lives on disk, so
# this keeps it warm — only the in-memory session is cleared.
#echo "==> Clearing any previous CC/wine session for a clean launch (wineserver -k)"
#WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
#sleep 2

# CC desktop is a CEF (Chromium 116, libcef.dll) app and its GPU process renders
# through DXVK. On a *cold* DXVK shader cache — which a GPU-driver update silently
# forces by invalidating the on-disk cache — CC's GPU process can't even create a
# command buffer ("Failed to send GpuControl.CreateCommandBuffer", kTransient
# failure) and CC.exe access-violates before it can rewarm the cache, i.e. a
# permanent crash loop that the warm-retry below can't break out of.
#
# CC.exe is itself the CEF browser process, so Chromium switches passed to it
# propagate: --disable-gpu / --disable-gpu-compositing put CC's UI on CPU render
# (no DXVK command buffer, no fault). The CC desktop UI is just panels/buttons —
# it has no use for the GPU — and this makes it immune to GPU-driver churn.
# (Lightroom Classic itself is a separate process and still gets real GPU via
# vkd3d-proton.)
#
# NOTE: do NOT add --in-process-gpu. It moves GPU work onto a thread inside the
# browser process; under wine that thread deadlocks holding a critical section
# ("RtlpWaitForCriticalSection ... blocked by <tid>, retrying (60 sec)") and the
# UI hangs on the loading spinner forever. --disable-gpu alone avoids the
# command-buffer crash without the deadlock.
# Override/extend with CC_CEF_ARGS; user args passed on the command line win last.
CC_CEF_ARGS="${CC_CEF_ARGS:---disable-gpu --disable-gpu-compositing}"

start_cc() {
  LD_PRELOAD= \
  DXVK_CONFIG_FILE="$PREFIX/dxvk.conf" \
  WINEPREFIX="$PREFIX" \
  WINEARCH=win64 \
  WINEDEBUG="$WINEDEBUG" \
  "$WINE" "$CC_EXE" $CC_CEF_ARGS "$@" &
  CC_BG=$!
}

# Auto-retry once. The FIRST launch on a (now cleared) cold DXVK shader cache can
# stall the CEF GPU process — the GPU command buffer times out ("GPU state
# invalid after WaitForGetOffsetInRange") and CC crashes before showing a window.
# That run still writes the DXVK cache to disk, so the relaunch is warm and comes
# up. Launch, poll up to CC_RETRY_DELAY s for the window; if it never appears,
# kill + relaunch once. CC_RETRY_DELAY=0 disables the retry.
CC_RETRY_DELAY="${CC_RETRY_DELAY:-15}"

echo "==> launching Creative Cloud desktop app (attempt 1)"
echo "    (Apps panel > install/update Lightroom Classic; sign in here if needed)"
start_cc "$@"

if [ "$CC_RETRY_DELAY" -gt 0 ] 2>/dev/null; then
  for _i in $(seq 1 "$CC_RETRY_DELAY"); do cc_window_up && break; sleep 1; done
  if ! cc_window_up; then
    # Do NOT kill the session here. attempt 1 (even when it crashed the UI) warms
    # the DXVK shader cache AND leaves Adobe's services up; attempt 2 reuses both
    # and comes up — exactly the manual "run it again" that works. Killing would
    # make attempt 2 cold and it would crash the same way.
    echo "==> No CC window after ${CC_RETRY_DELAY}s — relaunching once (warm now)"
    sleep 2
    echo "==> launching Creative Cloud desktop app (attempt 2)"
    start_cc "$@"
  fi
fi

wait "$CC_BG" 2>/dev/null || true
