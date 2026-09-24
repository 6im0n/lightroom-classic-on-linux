#!/usr/bin/env bash
# install-winrt-toast.sh — give the prefix a Windows.UI.Notifications
# ToastNotificationManager so the Creative Cloud app doesn't crash at startup.
#
# WHY: Creative Cloud 6.10 asks for the ToastNotificationManager WinRT factory
# while it initializes. wine has none, RoGetActivationFactory returns
# REGDB_E_CLASSNOTREG and Creative Cloud.exe dereferences the NULL factory
# (access violation at Creative Cloud.exe+0x65f9e): "Initializing Creative
# Cloud..." spins, then the app dies. winrt_toast.dll provides the factory and
# reports notifications as disabled. Source: resources/stubs/sources/winrt_toast.c
#
# Idempotent. run-creative-cloud.sh runs it on every launch, because a wine
# upgrade rewrites HKLM\...\WindowsRuntime\ActivatableClassId and drops the entry.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="${WINEPREFIX:-$REPO_DIR/wineprefix}"
WINE=${WINE:-wine}
DLL="$REPO_DIR/resources/stubs/binaries/winrt_toast.dll"
SYSTEM32="$PREFIX/drive_c/windows/system32"
KEY='HKLM\Software\Microsoft\WindowsRuntime\ActivatableClassId\Windows.UI.Notifications.ToastNotificationManager'

if [ ! -f "$DLL" ]; then
  echo "ERROR: $DLL not found" >&2
  exit 1
fi

if ! cmp -s "$DLL" "$SYSTEM32/winrt_toast.dll"; then
  cp -f "$DLL" "$SYSTEM32/winrt_toast.dll"
  echo "==> Installed system32/winrt_toast.dll"
fi

# (query the live registry; system.reg on disk is only flushed later)
if ! WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" reg query "$KEY" /v DllPath 2>/dev/null |
       grep -qi 'winrt_toast.dll'; then
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" reg add "$KEY" \
    /v DllPath /t REG_SZ /d 'C:\windows\system32\winrt_toast.dll' /f >/dev/null
  echo "==> Registered Windows.UI.Notifications.ToastNotificationManager"
fi
