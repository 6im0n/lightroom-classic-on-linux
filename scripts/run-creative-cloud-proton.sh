#!/usr/bin/env bash
# run-creative-cloud-proton.sh — launch the Creative Cloud desktop app via
# GE-Proton. Mirror of run-creative-cloud.sh: clean-start + auto-retry, but
# through umu-launcher / GE-Proton on the separate wineprefix-proton/.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proton-common.sh"

proton_preflight || exit 1
export DXVK_CONFIG_FILE="$PFX/dxvk.conf"
export DXVK_FRAME_RATE="${DXVK_FRAME_RATE:-60}"
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---disable-gpu}"
DRIVE_C=$(proton_drive_c)
CC_EXE_UNIX=""
for candidate in \
  "$DRIVE_C/Program Files/Adobe/Adobe Creative Cloud/ACC/Creative Cloud.exe" \
  "$DRIVE_C/Program Files (x86)/Adobe/Adobe Creative Cloud/ACC/Creative Cloud.exe"; do
  [ -f "$candidate" ] && { CC_EXE_UNIX="$candidate"; break; }
done
[ -n "$CC_EXE_UNIX" ] || CC_EXE_UNIX=$(find "$PFX" -maxdepth 8 -ipath "*Adobe Creative Cloud/ACC/Creative Cloud.exe" -print -quit 2>/dev/null || true)

if [ -z "$CC_EXE_UNIX" ]; then
  echo "ERROR: Creative Cloud not installed in the Proton prefix."
  echo "Run scripts/install-creative-cloud-proton.sh first."
  exit 1
fi
CC_EXE=$(proton_unix_path_to_win "$CC_EXE_UNIX")

# Run the CC UI under Windows 10 by default (no win11 Mica flicker, passes the
# OS check). Override with CC_WINVER=win7|win11.
pset_winver "${CC_WINVER:-win10}" >/dev/null 2>&1 || true
pset_x11_window_mode >/dev/null 2>&1 || true

# PID-based window detection (CC's window often has an empty title).
cc_window_up() {
  command -v wmctrl >/dev/null 2>&1 || return 1
  local id desk pid rest
  while read -r id desk pid rest; do
    [ -n "${pid:-}" ] && [ "$pid" != 0 ] || continue
    ps -p "$pid" -o args= 2>/dev/null | grep -qiE "Creative Cloud|Adobe" && return 0
  done < <(DISPLAY="${DISPLAY:-:0}" wmctrl -lp 2>/dev/null)
  return 1
}

# Clean start: kill any process tied to this Proton prefix so a fresh launch
# isn't swallowed by leftover Adobe services. (Scoped to wineprefix-proton/.)
echo "==> [proton] Clearing any previous session for a clean launch"
pkill -9 -f "$PFX" 2>/dev/null || true
sleep 2

# PROTON_DESKTOP=WxH runs inside a wine virtual desktop. On GNOME/Wayland this
# is enabled automatically unless PROTON_DESKTOP=off is set. It fixes a
# vertically offset mouse cursor on Xwayland + Mutter HiDPI scaling (wine draws
# its own cursor). e.g. PROTON_DESKTOP=2304x1296 scripts/run-creative-cloud-proton.sh
CC_RETRY_DELAY="${CC_RETRY_DELAY:-15}"
CC_CEF_ARGS="${CC_CEF_ARGS:---disable-gpu --disable-gpu-compositing}"
DESKTOP_SIZE=$(proton_desktop_size || true)
start_cc() {
  if [ -n "$DESKTOP_SIZE" ]; then
    # shellcheck disable=SC2086 # CC_CEF_ARGS intentionally expands to Chromium switches.
    uwine explorer /desktop="cc,$DESKTOP_SIZE" "$CC_EXE" $CC_CEF_ARGS "$@" &
    CC_BG=$!
    proton_position_window "cc" &
  else
    # shellcheck disable=SC2086 # CC_CEF_ARGS intentionally expands to Chromium switches.
    urun "$CC_EXE_UNIX" $CC_CEF_ARGS "$@" &
    CC_BG=$!
  fi
}

echo "==> [proton] launching Creative Cloud (attempt 1)"
echo "    (Apps panel > install/update Lightroom Classic; sign in if needed)"
[ -n "$DESKTOP_SIZE" ] && echo "    Using Wine virtual desktop: $DESKTOP_SIZE"
start_cc "$@"

if [ "$CC_RETRY_DELAY" -gt 0 ] 2>/dev/null; then
  for _i in $(seq 1 "$CC_RETRY_DELAY"); do cc_window_up && break; sleep 1; done
  if ! cc_window_up; then
    echo "==> No CC window after ${CC_RETRY_DELAY}s — relaunching once (warm now)"
    sleep 2
    echo "==> [proton] launching Creative Cloud (attempt 2)"
    start_cc "$@"
  fi
fi

wait "$CC_BG" 2>/dev/null || true
