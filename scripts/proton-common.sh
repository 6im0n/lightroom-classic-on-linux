#!/usr/bin/env bash
# proton-common.sh — shared environment + helpers for the GE-Proton variant.
#
# Source this from the *-proton.sh scripts. It runs everything through
# umu-launcher (umu-run), which drives a standalone GE-Proton build (no Steam):
# GE-Proton bundles tuned DXVK + vkd3d-proton + media-foundation (mfplat) + fsync,
# which fixes the codec/mfplat errors and tends to be faster + more stable than
# system wine for the Adobe CC/CEF UI.
#
# Prereqs:
#   * umu-launcher installed (Arch AUR: `umu-launcher`; provides `umu-run`).
#   * GE-Proton: set PROTONPATH to an extracted GE-Proton dir, OR leave it as the
#     default "GE-Proton" and umu-run auto-downloads the latest release for you.
#
# Everything lives in a SEPARATE prefix (wineprefix-proton/) so the system-wine
# setup is untouched. Use the matching *-proton.sh scripts (or ./start.sh once
# the Proton route is wired in).

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PFX="${WINEPREFIX:-$REPO_DIR/wineprefix-proton}"
export PFX

# GE-Proton build umu should use. "GE-Proton" = let umu fetch/keep latest.
PROTONPATH="${PROTONPATH:-GE-Proton}"
export PROTONPATH
# Non-Steam app: GAMEID 0. STORE none avoids store-specific fixes.
export GAMEID="${GAMEID:-0}"
export STORE="${STORE:-none}"
# Quiet DXVK/vkd3d device dumps; keep them with UMU_LOG=1 / DXVK_LOG_LEVEL=info.
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"
export VKD3D_DEBUG="${VKD3D_DEBUG:-none}"
# Xalia is Proton's gamepad/accessibility UI helper. It can spam/crash while
# inspecting launcher windows after their process exits, and Adobe does not need it.
export PROTON_USE_XALIA="${PROTON_USE_XALIA:-0}"
# Persist the DXVK shader cache so launches warm up across runs.
export DXVK_STATE_CACHE_PATH="${DXVK_STATE_CACHE_PATH:-$PFX/dxvk-cache}"
# Perf: fsync on (GE default), async shader compile (no stutter/stall).
export PROTON_NO_FSYNC="${PROTON_NO_FSYNC:-0}"
export DXVK_ASYNC="${DXVK_ASYNC:-1}"

proton_preflight() {
  if ! command -v umu-run >/dev/null 2>&1; then
    echo "ERROR: umu-run not found. Install umu-launcher first:"
    echo "       Arch:  yay -S umu-launcher   (or paru -S umu-launcher)"
    echo "       then re-run. GE-Proton itself is auto-downloaded by umu-run."
    return 1
  fi
  mkdir -p "$PFX" "$DXVK_STATE_CACHE_PATH" 2>/dev/null || true
  return 0
}

# urun <args...>  — run a program/command inside the GE-Proton environment.
#   urun "$SETUP"              -> run a Windows .exe (unix or C:\ path)
#   uwine reg add ...          -> run a Wine tool from the prefix
#   urun winetricks <verb>     -> winetricks against the Proton prefix
urun() {
  WINEPREFIX="$PFX" GAMEID="$GAMEID" STORE="$STORE" PROTONPATH="$PROTONPATH" \
    umu-run "$@"
}

# uwine <args...> — convenience for wine tool commands (reg, wineboot, …).
proton_drive_c() {
  find "$PFX" -maxdepth 3 -type d -name drive_c -print -quit 2>/dev/null || true
}

proton_runner_exe() {
  local exe="$1" base found
  if [ -n "${PROTONPATH:-}" ] && [ -d "$PROTONPATH" ] &&
     [ -f "$PROTONPATH/files/lib/wine/x86_64-windows/$exe" ]; then
    printf '%s\n' "$PROTONPATH/files/lib/wine/x86_64-windows/$exe"
    return 0
  fi
  for base in "$HOME/.local/share/Steam/compatibilitytools.d" "$HOME/.steam/root/compatibilitytools.d"; do
    [ -d "$base" ] || continue
    found=$(find "$base" -maxdepth 3 -path "*/files/lib/wine/x86_64-windows/$exe" -print -quit 2>/dev/null)
    [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
  done
  return 1
}

proton_prefix_exe() {
  local exe="$1" drive_c
  drive_c=$(proton_drive_c)
  if [ -n "$drive_c" ]; then
    case "$exe" in
      explorer.exe)
        [ -f "$drive_c/windows/explorer.exe" ] && { printf '%s\n' "$drive_c/windows/explorer.exe"; return 0; }
        ;;
      *)
        [ -f "$drive_c/windows/system32/$exe" ] && { printf '%s\n' "$drive_c/windows/system32/$exe"; return 0; }
        ;;
    esac
  fi
  proton_runner_exe "$exe"
}

uwine() {
  local tool="${1:-}" tool_exe exe
  [ $# -gt 0 ] || return 2
  shift
  case "$tool" in
    reg) tool_exe=reg.exe ;;
    wineboot) tool_exe=wineboot.exe ;;
    explorer) tool_exe=explorer.exe ;;
    cmd) tool_exe=cmd.exe ;;
    *) echo "uwine: unsupported Proton tool: $tool" >&2; return 2 ;;
  esac
  exe=$(proton_prefix_exe "$tool_exe" || true)
  [ -n "$exe" ] || exe="$tool_exe"
  urun "$exe" "$@"
}

proton_unix_path_to_z() {
  local path="$1"
  case "$path" in
    [A-Za-z]:*) printf '%s\n' "$path" ;;
    /*) printf 'Z:%s\n' "${path//\//\\}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

proton_unix_path_to_win() {
  local path="$1" drive_c rel
  drive_c=$(proton_drive_c)
  if [ -n "$drive_c" ]; then
    case "$path" in
      "$drive_c"/*)
        rel="${path#"$drive_c"/}"
        rel="${rel//\//\\}"
        printf 'C:\\%s\n' "$rel"
        return 0
        ;;
    esac
  fi
  proton_unix_path_to_z "$path"
}

proton_win_path_to_unix() {
  local path="$1" drive_c rel
  case "$path" in
    [Cc]:\\*)
      drive_c=$(proton_drive_c)
      [ -n "$drive_c" ] || return 1
      rel="${path#?:\\}"
      rel="${rel//\\//}"
      printf '%s/%s\n' "$drive_c" "$rel"
      ;;
    *) printf '%s\n' "$path" ;;
  esac
}

proton_is_gnome_wayland() {
  [ "${XDG_SESSION_TYPE:-}" = wayland ] ||
    printf '%s' "${XDG_CURRENT_DESKTOP:-} ${DESKTOP_SESSION:-}" | grep -qi gnome
}

proton_fit_desktop_size() {
  local size="$1" width height margin_x margin_y min_w min_h
  case "$size" in
    *x*) ;;
    *) printf '%s\n' "$size"; return 0 ;;
  esac

  width="${size%x*}"
  height="${size#*x}"
  margin_x="${PROTON_DESKTOP_MARGIN_X:-}"
  margin_y="${PROTON_DESKTOP_MARGIN_Y:-}"
  if [ -z "$margin_x" ] || [ -z "$margin_y" ]; then
    if proton_is_gnome_wayland; then
      margin_x="${margin_x:-160}"
      margin_y="${margin_y:-260}"
    else
      margin_x="${margin_x:-0}"
      margin_y="${margin_y:-0}"
    fi
  fi

  min_w="${PROTON_DESKTOP_MIN_W:-1024}"
  min_h="${PROTON_DESKTOP_MIN_H:-720}"
  width=$((width - margin_x))
  height=$((height - margin_y))
  [ "$width" -lt "$min_w" ] && width="$min_w"
  [ "$height" -lt "$min_h" ] && height="$min_h"
  printf '%sx%s\n' "$width" "$height"
}

proton_position_window() {
  local title="$1" x="${PROTON_WINDOW_X:-80}" y="${PROTON_WINDOW_Y:-120}" tries="${PROTON_WINDOW_POSITION_TRIES:-30}"
  command -v wmctrl >/dev/null 2>&1 || return 0
  while [ "$tries" -gt 0 ]; do
    if DISPLAY="${DISPLAY:-:0}" wmctrl -r "$title" -e "0,$x,$y,-1,-1" 2>/dev/null; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.5
  done
  return 0
}

proton_auto_desktop_size() {
  local size scale width height
  if command -v xrandr >/dev/null 2>&1; then
    size=$(DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null | awk '/\*/ { print $1; exit }')
    if [ -n "$size" ]; then
      scale=$(gsettings get org.gnome.desktop.interface scaling-factor 2>/dev/null | awk '/uint32/ { print $2 }')
      if [ "${scale:-0}" -gt 1 ] 2>/dev/null; then
        width="${size%x*}"
        height="${size#*x}"
        proton_fit_desktop_size "$((width / scale))x$((height / scale))"
      else
        proton_fit_desktop_size "$size"
      fi
      return 0
    fi
  fi
  if command -v xdpyinfo >/dev/null 2>&1; then
    size=$(DISPLAY="${DISPLAY:-:0}" xdpyinfo 2>/dev/null | awk '/dimensions:/ { print $2; exit }')
    [ -n "$size" ] && { proton_fit_desktop_size "$size"; return 0; }
  fi
  proton_fit_desktop_size "${PROTON_DESKTOP_FALLBACK:-1920x1080}"
}

proton_desktop_size() {
  local requested="${PROTON_DESKTOP:-}"
  case "$requested" in
    0|off|OFF|false|FALSE|no|NO) return 1 ;;
    auto|AUTO) proton_auto_desktop_size ;;
    "")
      [ "${PROTON_DESKTOP_AUTO:-1}" = 0 ] && return 1
      if proton_is_gnome_wayland; then
        proton_auto_desktop_size
      else
        return 1
      fi
      ;;
    *) printf '%s\n' "$requested" ;;
  esac
}

# pset_winver win7|win10|win11 — set the reported Windows version without
# winetricks/wineboot. Import one .reg file so umu/Proton only starts once.
pset_winver() {
  local ver="${1:-}" cv build pn major minor
  case "$ver" in
    win7)  cv=6.1;  build=7601;  pn="Microsoft Windows 7";  major=6;  minor=1 ;;
    win10) cv=10.0; build=19045; pn="Microsoft Windows 10"; major=10; minor=0 ;;
    win11) cv=10.0; build=22000; pn="Microsoft Windows 11"; major=10; minor=0 ;;
    *) echo "pset_winver: need win7|win10|win11"; return 2 ;;
  esac

  local drive_c reg_file win_reg_file
  drive_c=$(find "$PFX" -maxdepth 3 -type d -name drive_c -print -quit 2>/dev/null || true)
  if [ -n "$drive_c" ]; then
    reg_file="$drive_c/proton-winver.reg"
    win_reg_file='C:\proton-winver.reg'
  else
    reg_file="${TMPDIR:-/tmp}/proton-winver-$$.reg"
    win_reg_file=$(proton_unix_path_to_z "$reg_file")
  fi

  {
    printf 'REGEDIT4\n\n'
    printf '[HKEY_CURRENT_USER\\Software\\Wine]\n'
    printf '"Version"="%s"\n\n' "$ver"
    printf '[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion]\n'
    printf '"CurrentVersion"="%s"\n' "$cv"
    printf '"CurrentBuild"="%s"\n' "$build"
    printf '"CurrentBuildNumber"="%s"\n' "$build"
    printf '"ProductName"="%s"\n' "$pn"
    if [ "$ver" = win7 ]; then
      printf '"CurrentMajorVersionNumber"=-\n'
      printf '"CurrentMinorVersionNumber"=-\n'
    else
      printf '"CurrentMajorVersionNumber"=dword:%08x\n' "$major"
      printf '"CurrentMinorVersionNumber"=dword:%08x\n' "$minor"
    fi
  } > "$reg_file"

  uwine reg import "$win_reg_file" >/dev/null 2>&1 || true
  rm -f "$reg_file" 2>/dev/null || true

  echo "==> [proton] Windows version = $ver (build $build)"
}

pset_x11_window_mode() {
  local drive_c reg_file win_reg_file
  drive_c=$(proton_drive_c)
  if [ -n "$drive_c" ]; then
    reg_file="$drive_c/proton-x11-window-mode.reg"
    win_reg_file='C:\proton-x11-window-mode.reg'
  else
    reg_file="${TMPDIR:-/tmp}/proton-x11-window-mode-$$.reg"
    win_reg_file=$(proton_unix_path_to_z "$reg_file")
  fi

  {
    printf 'REGEDIT4\n\n'
    printf '[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]\n'
    printf '"Managed"="%s"\n' "${PROTON_X11_MANAGED:-Y}"
    printf '"Decorated"="%s"\n' "${PROTON_X11_DECORATED:-Y}"
  } > "$reg_file"

  uwine reg import "$win_reg_file" >/dev/null 2>&1 || true
  rm -f "$reg_file" 2>/dev/null || true
}
