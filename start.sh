#!/usr/bin/env bash
# start.sh — friendly hub for running Adobe Lightroom Classic on Linux via wine.
#
# Detects how far the setup has got and offers the right next actions in an
# interactive menu. Just run it:  ./start.sh   (or ./start.sh --verbose to also
# show each action's error output / wine err: lines).
#
# It only orchestrates the scripts in resources/scripts/ — every action is one of those
# scripts, so nothing here is magic; you can always run them directly.

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX="$REPO_DIR/wineprefix"
S="$REPO_DIR/resources/scripts"
WINE=${WINE:-wine}

# Lightroom UI scale chosen via the menu (empty = let the launcher use its 144
# default). Applied to runs 7/8 as --dpi=N. Set with menu option 'd'.
LR_DPI_SET=""

# --verbose / -v : show the actions' stderr (wine err: lines, traces, etc).
# Default: stderr is hidden so the menu stays clean (stdout progress still shows).
VERBOSE=0
for _a in "$@"; do
  case "$_a" in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) echo "usage: ./start.sh [--verbose]"; exit 0 ;;
    *) echo "unknown option: $_a (use --verbose or --help)"; exit 2 ;;
  esac
done

# colours (fall back to empty if not a tty)
if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; Z=$'\e[0m'
else B=; DIM=; G=; Y=; R=; C=; Z=; fi

CHECK=$'✓'; CROSS=$'✗'; ARROW=$'←'; TRI=$'▶'

ok()   { printf '%s' "${G}${CHECK}${Z}"; }   # green check
no()   { printf '%s' "${R}${CROSS}${Z}"; }   # red cross

# ---------------------------------------------------------------------------
# State detection
# ---------------------------------------------------------------------------
detect() {
  HAVE_WINE=0;   command -v "$WINE" >/dev/null 2>&1 && HAVE_WINE=1
  PREFIX_READY=0
  [ -f "$PREFIX/system.reg" ] && [ -f "$PREFIX/.setup-verbs-done" ] && PREFIX_READY=1
  # vkd3d-proton is "done" only when its native d3d12 DLL override is set
  # (install-vkd3d-proton.sh writes it; setup.sh never does). Checking the file
  # alone is wrong — wine ships a builtin d3d12core.dll, so it's always present.
  GPU_DONE=0
  grep -q '"d3d12"="native"' "$PREFIX/user.reg" 2>/dev/null && GPU_DONE=1
  CC_INSTALLED=0
  [ -f "$PREFIX/drive_c/Program Files/Adobe/Adobe Creative Cloud/ACC/Creative Cloud.exe" ] && CC_INSTALLED=1
  LR_INSTALLED=0
  [ -f "$PREFIX/drive_c/Program Files/Adobe/Adobe Lightroom Classic/Lightroom.exe" ] && LR_INSTALLED=1
  FIXES_DONE=0
  LRD="$PREFIX/drive_c/Program Files/Adobe/Adobe Lightroom Classic"
  if [ "$LR_INSTALLED" = 1 ] && { [ -f "$LRD/AdobeGrowthSDK.dll.disabled" ] || [ ! -f "$LRD/AdobeGrowthSDK.dll" ]; }; then
    FIXES_DONE=1
  fi
  # standalone installer available?
  STANDALONE=0
  [ -f "$REPO_DIR/resources/installers/lightroom/Set-up.exe" ] && STANDALONE=1
  # CC offline installer available?
  CC_ZIP=0
  ls "$REPO_DIR"/resources/installers/ACCCx*.zip >/dev/null 2>&1 && CC_ZIP=1

  # recommended next step (one of: setup gpu install runcc fixes runlr).
  # Order: setup -> GPU -> install -> (run CC to install LR) -> fixes -> run LR.
  if   [ "$PREFIX_READY" = 0 ];                            then NEXT=setup
  elif [ "$GPU_DONE" = 0 ];                                then NEXT=gpu
  elif [ "$CC_INSTALLED" = 0 ] && [ "$LR_INSTALLED" = 0 ]; then NEXT=install
  elif [ "$CC_INSTALLED" = 1 ] && [ "$LR_INSTALLED" = 0 ]; then NEXT=runcc
  elif [ "$LR_INSTALLED" = 1 ] && [ "$FIXES_DONE" = 0 ];   then NEXT=fixes
  else                                                          NEXT=runlr
  fi
}

mark() { [ "$NEXT" = "$1" ] && printf '%s' "  ${Y}${ARROW} recommended${Z}"; }
flag() { [ "$1" = 1 ] && ok || no; }
# wine LogPixels DPI -> scale percent (96 dpi = 100%).
dpi_pct() { echo $(( $1 * 100 / 96 )); }

# ---------------------------------------------------------------------------
# Status panel
# ---------------------------------------------------------------------------
banner() {
  detect
  clear 2>/dev/null || true
  echo "${B}${C}  Adobe Lightroom Classic on Linux  ${Z}"
  echo "${DIM}  $REPO_DIR${Z}"
  echo
  if [ "$HAVE_WINE" = 0 ]; then
    echo "  ${R}wine not found in PATH${Z} — install wine (>= 11.8 staging) first."
    echo
  fi
  printf '  %b  wine prefix prepared\n'        "$(flag "$PREFIX_READY")"
  printf '  %b  GPU acceleration (vkd3d)\n'     "$(flag "$GPU_DONE")"
  printf '  %b  Creative Cloud app installed\n' "$(flag "$CC_INSTALLED")"
  printf '  %b  Lightroom Classic installed\n'  "$(flag "$LR_INSTALLED")"
  printf '  %b  post-install fixes applied\n'   "$(flag "$FIXES_DONE")"
  echo
}

# run a script, then pause so the user can read output before the menu redraws.
# stderr is hidden unless --verbose (keeps the menu clean of wine err: spam).
run() {
  echo; echo "${C}${TRI} $*${Z}"; echo
  if [ "$VERBOSE" = 1 ]; then "$@"; else "$@" 2>/dev/null; fi
  local rc=$?
  echo
  if [ $rc -eq 0 ]; then echo "${G}done.${Z}"; else echo "${R}exited with code $rc.${Z}"; fi
  [ "$VERBOSE" = 1 ] || echo "${DIM}(re-run with --verbose to see error output)${Z}"
  printf '\nPress Enter to return to the menu... '; read -r _
}

# ---------------------------------------------------------------------------
# Menu loop
# ---------------------------------------------------------------------------
while true; do
  banner
  if [ "$VERBOSE" = 1 ]; then _vmode="${G}verbose${Z}${DIM}"; else _vmode="quiet"; fi
  echo "${B}  Actions${Z}   ${DIM}(number, or q to quit • errors: ${_vmode})${Z}"
  echo
  echo "${DIM}  ----------- Wine installation --------------${Z}"
  printf '   1) Prepare wine prefix (setup)%b\n'                "$(mark setup)"
  printf '   2) Install GPU acceleration (vkd3d-proton)%b\n'    "$(mark gpu)"
  echo
  echo "${DIM}  --------------------- Install part -----------------${Z}"
  echo   "      ${DIM}Install Lightroom Classic — three routes:${Z}"
  printf "   3) via Creative Cloud — online installer  ${DIM}(recommended; bundles CoreSync)${Z}%b\n"  "$(mark install)"
  printf "   4) via Creative Cloud — offline ACCCx.zip  ${DIM}(back-version;)${Z}\n"
  printf '   5) via standalone Set-up.exe\n'
  printf '   6) Post-install fixes%b\n'                         "$(mark fixes)"
  echo
  if [ -n "$LR_DPI_SET" ]; then _dpilbl="$(dpi_pct "$LR_DPI_SET")% (${LR_DPI_SET} dpi)"; else _dpilbl="default 150% (144 dpi)"; fi
  echo "${DIM}  -------------- Run apps ---------------------${Z}"
  printf '   7) Run Lightroom Classic%b\n'                      "$(mark runlr)"
  printf "   8) Run Lightroom Classic ${DIM}— virtual desktop (fallback if something crashes)${Z}\n"
  printf "   9) Run Creative Cloud app          ${DIM}(Win10)${Z}%b\n"  "$(mark runcc)"
  printf "   d) Lightroom UI scale ${DIM}[current: %s]${Z}\n"   "$_dpilbl"
  printf "   g) Add to application menu ${DIM}(desktop launcher)${Z}\n"
  echo
  echo "${DIM}  --------------- Other ------------------${Z}"
  printf '  10) Set Windows version manually (win7/win10/win11)\n'
  printf "   ${R}k) Kill the wine session${Z} ${DIM}(wineserver -k — use if an app hangs/won't relaunch)${Z}\n"
  printf '   r) Reset / wipe the prefix (start over)\n'
  printf '   q) Quit\n'
  echo
  printf '  > '
  read -r choice || break

  case "$choice" in
    1) run "$S/wine/setup.sh" ;;
    2) if [ "$PREFIX_READY" = 1 ]; then run "$S/wine/install-vkd3d-proton.sh"
       else echo "  ${Y}Run setup (1) first.${Z}"; sleep 1.5; fi ;;
    3) if [ "$PREFIX_READY" = 1 ]; then run "$S/creative-cloud/install-creative-cloud-live.sh"
       else echo "  ${Y}Run setup (1) first.${Z}"; sleep 1.5; fi ;;
    4) if [ "$PREFIX_READY" = 1 ]; then run "$S/creative-cloud/install-creative-cloud.sh"
       else echo "  ${Y}Run setup (1) first.${Z}"; sleep 1.5; fi ;;
    5) if [ "$PREFIX_READY" = 1 ]; then run "$S/lightroom/install-lightroom-classic.sh"
       else echo "  ${Y}Run setup (1) first.${Z}"; sleep 1.5; fi ;;
    6) if [ "$LR_INSTALLED" = 1 ]; then run "$S/lightroom/install-lightroom-classic-fixes.sh"
       else echo "  ${Y}Install Lightroom Classic first (3, 4 or 5).${Z}"; sleep 1.5; fi ;;
    7) if [ "$LR_INSTALLED" = 1 ]; then run "$S/lightroom/run-lightroom-classic.sh" ${LR_DPI_SET:+--dpi=$LR_DPI_SET}
       else echo "  ${Y}Lightroom Classic is not installed yet.${Z}"; sleep 1.5; fi ;;
    8) if [ "$LR_INSTALLED" = 1 ]; then run "$S/lightroom/run-lightroom-classic.sh" --vdesktop ${LR_DPI_SET:+--dpi=$LR_DPI_SET}
       else echo "  ${Y}Lightroom Classic is not installed yet.${Z}"; sleep 1.5; fi ;;
    9) if [ "$CC_INSTALLED" = 1 ]; then run "$S/creative-cloud/run-creative-cloud.sh"
       else echo "  ${Y}The Creative Cloud app is not installed yet (3).${Z}"; sleep 1.5; fi ;;
    10) if [ "$PREFIX_READY" = 1 ]; then
         printf '  which version? [win7/win10/win11]: '; read -r v
         case "$v" in win7|win10|win11) run "$S/wine/set-winver.sh" "$v" ;;
           *) echo "  ${Y}pick win7, win10 or win11${Z}"; sleep 1.5 ;; esac
       else echo "  ${Y}Run setup (1) first.${Z}"; sleep 1.5; fi ;;
    k|K) echo; echo "${C}${TRI} Killing the wine session (wineserver -k)${Z}"; echo
         echo "  ${DIM}Stops every wine process in this prefix (hung Adobe apps,${Z}"
         echo "  ${DIM}stale background services). Your install, settings and the${Z}"
         echo "  ${DIM}DXVK shader cache are untouched — only running processes die.${Z}"
         if WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null; then
           echo "  ${G}done — wine session cleared. Relaunch the app.${Z}"
         else
           echo "  ${Y}nothing was running.${Z}"
         fi
         printf '\nPress Enter to return to the menu... '; read -r _ ;;
    d|D) echo; echo "${C}${TRI} Lightroom UI scale (DPI)${Z}"; echo
         echo "  ${DIM}Bigger % = bigger UI. wine renders at 96 dpi = 100% by default.${Z}"
         echo "    1) 100%  (96 dpi)"
         echo "    2) 125%  (120 dpi)"
         echo "    3) 150%  (144 dpi)  ${DIM}default${Z}"
         echo "    4) 175%  (168 dpi)"
         echo "    5) 200%  (192 dpi)"
         echo "    6) 250%  (240 dpi)"
         echo "    7) 300%  (288 dpi)"
         printf '  choose [1-7, or a raw dpi like 216]: '; read -r d
         _newdpi=""
         case "$d" in
           1) _newdpi=96 ;;  2) _newdpi=120 ;; 3) _newdpi=144 ;; 4) _newdpi=168 ;;
           5) _newdpi=192 ;; 6) _newdpi=240 ;; 7) _newdpi=288 ;;
           ''|*[!0-9]*) echo "  ${Y}invalid — pick 1-7 or a dpi number${Z}"; sleep 1.2 ;;
           *) if [ "$d" -ge 96 ]; then _newdpi="$d"
              else echo "  ${Y}minimum is 96 (100%)${Z}"; sleep 1.2; fi ;;
         esac
         if [ -n "$_newdpi" ]; then
           LR_DPI_SET="$_newdpi"
           echo "  ${G}UI scale: $(dpi_pct "$LR_DPI_SET")% (${LR_DPI_SET} dpi) — applies to runs 7 and 8.${Z}"
           sleep 1.2
         fi ;;
    g|G) if [ "$LR_INSTALLED" = 0 ]; then
           echo "  ${Y}Lightroom Classic is not installed yet.${Z}"; sleep 1.5
         else
           echo; echo "${C}${TRI} Add Lightroom Classic to the application menu${Z}"; echo
           echo "  ${DIM}Creates a desktop launcher that starts Lightroom through${Z}"
           echo "  ${DIM}run-lightroom-classic.sh (with all fixes), replacing wine's${Z}"
           echo "  ${DIM}broken auto-generated entry.${Z}"; echo
           # 1) UI scale / DPI
           echo "  ${B}UI scale${Z} ${DIM}(96 dpi = 100%):${Z}"
           echo "    1) 100%  (96 dpi)"
           echo "    2) 125%  (120 dpi)"
           echo "    3) 150%  (144 dpi)  ${DIM}default${Z}"
           echo "    4) 175%  (168 dpi)"
           echo "    5) 200%  (192 dpi)"
           echo "    6) 250%  (240 dpi)"
           echo "    7) 300%  (288 dpi)"
           printf '  choose [1-7, a raw dpi like 216, or Enter for default]: '; read -r d
           _gdpi=""
           case "$d" in
             1) _gdpi=96 ;;  2) _gdpi=120 ;; 3) _gdpi=144 ;; 4) _gdpi=168 ;;
             5) _gdpi=192 ;; 6) _gdpi=240 ;; 7) _gdpi=288 ;;
             '') _gdpi="" ;;
             *[!0-9]*) echo "  ${Y}invalid — using default${Z}"; _gdpi="" ;;
             *) if [ "$d" -ge 96 ]; then _gdpi="$d"; else echo "  ${Y}minimum is 96 — using default${Z}"; _gdpi=""; fi ;;
           esac
           # 2) virtual desktop on/off
           echo
           printf "  ${B}Virtual desktop?${Z} ${DIM}(crash fallback; off unless something crashes)${Z} [y/N]: "; read -r vd
           _gvd=""
           case "$vd" in y|Y|yes|YES) _gvd="--vdesktop" ;; esac
           run "$S/lightroom/install-desktop-entry.sh" ${_gdpi:+--dpi=$_gdpi} $_gvd
         fi ;;
    r|R) run "$S/wine/reset-wineprefix.sh" ;;
    q|Q|"") echo "bye."; exit 0 ;;
    *) echo "  ${Y}unknown choice: $choice${Z}"; sleep 1 ;;
  esac
done
