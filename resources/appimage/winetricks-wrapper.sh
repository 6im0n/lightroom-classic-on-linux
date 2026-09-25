#!/usr/bin/env bash
# winetricks-wrapper.sh — the AppImage's `winetricks`: pins DXVK + vkd3d-proton.
#
# Installed in the AppDir as usr/bin/winetricks (first in PATH, and $WINETRICKS
# points at it). The repo scripts call `winetricks -q … dxvk` and
# `winetricks -q vkd3d`, and the real winetricks would install the newest
# release of each. This wrapper instead installs the copies fetch-deps.sh put
# in <AppDir>/deps (versions from deps.lock), the same way winetricks does:
# 64-bit DLLs in system32, 32-bit in syswow64, DllOverrides set to native.
# Every other verb and option goes to the pinned real winetricks unchanged.
#
# Any dxvk* / vkd3d* verb (e.g. dxvk2071) gets the pinned version too: the
# point of the bundle is that nothing installs a different one.

set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
DEPS=${LR_DEPS_DIR:-${APPDIR:-$HERE/../..}/deps}
REAL="$DEPS/winetricks/winetricks"
WINE=${WINE:-wine}
PREFIX=${WINEPREFIX:-$HOME/.wine}

# Split the arguments: our verbs vs everything for the real winetricks.
pass=() pinned=() verbs=0
for a in "$@"; do
  case "$a" in
    dxvk*)  pinned+=(dxvk) ;;
    vkd3d*) pinned+=(vkd3d) ;;
    -*)     pass+=("$a") ;;
    *)      pass+=("$a"); verbs=$((verbs + 1)) ;;
  esac
done

# Real winetricks first, in the caller's order. With only options left (no
# verb) it would open its GUI, so skip it then — unless nothing was pinned
# (the caller really did run bare `winetricks`).
if [ "$verbs" -gt 0 ] || [ "${#pinned[@]}" -eq 0 ]; then
  "$REAL" "${pass[@]+"${pass[@]}"}"
fi

# install_dlls <src-dir> <dst-dir> <dll>...
install_dlls() {
  local src=$1 dst=$2; shift 2
  for d in "$@"; do cp -f "$src/$d.dll" "$dst/$d.dll"; done
}

override_native() {
  for d in "$@"; do
    WINEPREFIX="$PREFIX" "$WINE" reg ADD 'HKCU\Software\Wine\DllOverrides' \
      /v "$d" /t REG_SZ /d native /f >/dev/null 2>&1
  done
}

# shellcheck source=deps.lock
. "$DEPS/deps.lock"
SYS32="$PREFIX/drive_c/windows/system32"
SYSWOW64="$PREFIX/drive_c/windows/syswow64"

for p in $(printf '%s\n' "${pinned[@]+"${pinned[@]}"}" | sort -u); do
  case "$p" in
    dxvk)
      echo "==> Installing pinned DXVK $DXVK_VERSION (AppImage bundle)"
      set -- d3d8 d3d9 d3d10core d3d11 dxgi
      install_dlls "$DEPS/dxvk/x64" "$SYS32" "$@"
      install_dlls "$DEPS/dxvk/x32" "$SYSWOW64" "$@"
      override_native "$@"
      echo "$DXVK_VERSION" > "$PREFIX/.appimage-dxvk" ;;
    vkd3d)
      # 64-bit only, like install-vkd3d-proton.sh. Lightroom is 64-bit; the
      # 32-bit processes that probe D3D12 must keep wine's builtin: Adobe
      # Desktop Service (32-bit) dies on 32-bit vkd3d-proton while running
      # Camera Raw's compatibility check, and the Creative Cloud Apps tab
      # then never loads (so CoreSync is never installed).
      echo "==> Installing pinned vkd3d-proton $VKD3D_PROTON_VERSION (AppImage bundle, 64-bit)"
      set -- d3d12 d3d12core
      install_dlls "$DEPS/vkd3d-proton/x64" "$SYS32" "$@"
      override_native "$@"
      echo "$VKD3D_PROTON_VERSION" > "$PREFIX/.appimage-vkd3d-proton" ;;
  esac
done
