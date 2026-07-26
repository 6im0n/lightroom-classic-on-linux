#!/usr/bin/env bash
# run-creative-cloud-proton.sh — launch the Creative Cloud desktop app via
# GE-Proton. Mirror of run-creative-cloud.sh: clean-start + auto-retry, but
# through umu-launcher / GE-Proton on the separate wineprefix-proton/.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proton-common.sh"

proton_preflight || exit 1
export DXVK_CONFIG_FILE="$PFX/dxvk.conf"
CC_EXE='C:\Program Files\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe'

if ! find "$PFX" -maxdepth 5 -ipath "*Adobe Creative Cloud/ACC/Creative Cloud.exe" 2>/dev/null | grep -q .; then
  echo "ERROR: Creative Cloud not installed in the Proton prefix."
  echo "Run scripts/install-creative-cloud-proton.sh first."
  exit 1
fi

# Run the CC UI under Windows 10 by default (no win11 Mica flicker, passes the
# OS check). Override with CC_WINVER=win7|win11.
pset_winver "${CC_WINVER:-win10}" >/dev/null 2>&1 || true

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

# PROTON_DESKTOP=WxH runs inside a wine virtual desktop — fixes a vertically
# offset mouse cursor on Xwayland + Mutter HiDPI scaling (wine draws its own
# cursor). e.g. PROTON_DESKTOP=2304x1296 scripts/run-creative-cloud-proton.sh
CC_RETRY_DELAY="${CC_RETRY_DELAY:-15}"
start_cc() {
  if [ -n "${PROTON_DESKTOP:-}" ]; then
    urun wine explorer /desktop="cc,$PROTON_DESKTOP" "$CC_EXE" "$@" &
  else
    urun wine "$CC_EXE" "$@" &
  fi
  CC_BG=$!
}

echo "==> [proton] launching Creative Cloud (attempt 1)"
echo "    (Apps panel > install/update Lightroom Classic; sign in if needed)"
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
