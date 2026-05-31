#!/usr/bin/env bash
# set-winver.sh — switch the prefix's reported Windows version on the fly.
#
#   resources/scripts/wine/set-winver.sh win7     # no DWM/Mica -> the CC/CEF UI stops flickering
#   resources/scripts/wine/set-winver.sh win11    # build 22000 -> Adobe's ESD OS check passes
#   resources/scripts/wine/set-winver.sh win10    # build 19045 -> also passes the OS check
#
# Why both: the Creative Cloud UI (CEF/Electron) flickers under win11 on
# wine/Xwayland, but Adobe's installers do an OS-version check that REJECTS win7
# ("upgrade your OS"). So sign in under win7 (stable), then flip to win11 for the
# install. wine reports the version via RtlGetVersion, which it derives from the
# HKCU\Software\Wine\Version override — so this is a couple of fast `wine reg`
# writes. It does NOT call winetricks (winetricks runs wineboot/`wineserver -w`,
# which DEADLOCKS a running installer: "RtlpWaitForCriticalSection ... wait timed
# out ... retrying (60 sec)"). Takes effect for processes started AFTER it runs.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
export WINEPREFIX="$REPO_DIR/wineprefix"
export WINEDEBUG=-all
WINE=${WINE:-wine}

ver="${1:-}"
case "$ver" in
  win7)  cv="6.1";  build="7601";  pn="Microsoft Windows 7";  major=6;  minor=1 ;;
  win10) cv="10.0"; build="19045"; pn="Microsoft Windows 10"; major=10; minor=0 ;;
  win11) cv="10.0"; build="22000"; pn="Microsoft Windows 11"; major=10; minor=0 ;;
  *) echo "usage: $(basename "$0") win7|win10|win11"; exit 2 ;;
esac

if [ ! -f "$WINEPREFIX/system.reg" ]; then
  echo "ERROR: no wine prefix at $WINEPREFIX (run setup first)"; exit 1
fi

echo "==> setting Windows version to $ver (build $build) ..."

# 1) The canonical wine mechanism: the per-prefix version override drives
#    RtlGetVersion / GetVersionEx (what Adobe's OS check reads, e.g. "6.1.7601").
$WINE reg ADD 'HKCU\Software\Wine' /v Version /t REG_SZ /d "$ver" /f >/dev/null 2>&1 || true

# 2) Belt-and-suspenders: also write the HKLM version keys, for any component
#    that reads them from the registry directly.
CV='HKLM\Software\Microsoft\Windows NT\CurrentVersion'
$WINE reg ADD "$CV" /v CurrentVersion     /t REG_SZ /d "$cv"    /f >/dev/null 2>&1 || true
$WINE reg ADD "$CV" /v CurrentBuild       /t REG_SZ /d "$build" /f >/dev/null 2>&1 || true
$WINE reg ADD "$CV" /v CurrentBuildNumber /t REG_SZ /d "$build" /f >/dev/null 2>&1 || true
$WINE reg ADD "$CV" /v ProductName        /t REG_SZ /d "$pn"    /f >/dev/null 2>&1 || true
if [ "$ver" = win7 ]; then
  $WINE reg DELETE "$CV" /v CurrentMajorVersionNumber /f >/dev/null 2>&1 || true
  $WINE reg DELETE "$CV" /v CurrentMinorVersionNumber /f >/dev/null 2>&1 || true
else
  $WINE reg ADD "$CV" /v CurrentMajorVersionNumber /t REG_DWORD /d "$major" /f >/dev/null 2>&1 || true
  $WINE reg ADD "$CV" /v CurrentMinorVersionNumber /t REG_DWORD /d "$minor" /f >/dev/null 2>&1 || true
fi

echo "==> done: $ver"
