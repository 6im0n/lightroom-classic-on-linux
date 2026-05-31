#!/usr/bin/env bash
# reset-wineprefix.sh — wipe the wine prefix back to nothing.
#
# Deletes wineprefix/ entirely: every Adobe app (Lightroom Classic, Creative
# Cloud, Photoshop, …), all winetricks verbs, the installed/patched DLLs, the
# whole registry — AND the Lightroom catalog + your edits/settings that live
# inside it. After this, the repo is at a clean "fresh wine" state; re-run
# resources/scripts/wine/setup.sh (then the install scripts) to rebuild from scratch.
#
# KEPT by default: the downloaded installers under resources/installers/ (Set-up.exe,
# ACCCx*.zip, wine-gecko, WebView2) so a reinstall doesn't re-download them.
# Pass --purge-installers to also delete those.
#
# This is IRREVERSIBLE and there is NO backup. You will be asked to type "yes"
# unless you pass -y/--yes (or set FORCE=1).
#
# Usage:
#   resources/scripts/wine/reset-wineprefix.sh                 # wipe prefix (asks to confirm)
#   resources/scripts/wine/reset-wineprefix.sh -y              # no prompt
#   resources/scripts/wine/reset-wineprefix.sh --purge-installers   # also delete resources/installers/

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="$REPO_DIR/wineprefix"
WINE=${WINE:-wine}

ASSUME_YES="${FORCE:-0}"
PURGE_INSTALLERS=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)            ASSUME_YES=1 ;;
    --purge-installers)  PURGE_INSTALLERS=1 ;;
    -h|--help)
      awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ ! -e "$PREFIX" ]; then
  echo "==> No wineprefix at $PREFIX — nothing to delete (already clean)."
  [ "$PURGE_INSTALLERS" = 0 ] && exit 0
fi

# ---------------------------------------------------------------------------
# Confirm — this is destructive and unrecoverable.
# ---------------------------------------------------------------------------
SIZE=$(du -sh "$PREFIX" 2>/dev/null | cut -f1 || echo "?")
echo "About to PERMANENTLY DELETE the wine prefix:"
echo "    $PREFIX   ($SIZE)"
echo
echo "This removes ALL installed apps (Lightroom Classic, Creative Cloud,"
echo "Photoshop…), every winetricks verb, the patched DLLs, the full registry,"
echo "and the Lightroom catalog + edits/settings inside the prefix."
[ "$PURGE_INSTALLERS" = 1 ] && echo "It will ALSO delete the downloaded installers in resources/installers/."
echo "There is NO backup. This cannot be undone."
echo
if [ "$ASSUME_YES" != 1 ]; then
  printf 'Type "yes" to proceed: '
  read -r reply
  if [ "$reply" != "yes" ]; then
    echo "Aborted — nothing deleted."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Stop anything using the prefix, then delete it.
# ---------------------------------------------------------------------------
if [ -e "$PREFIX/system.reg" ]; then
  echo "==> Shutting down wineserver for this prefix"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE"server -k 2>/dev/null || true
  # kill any lingering processes whose command line references this prefix
  # (Adobe IPC broker / update / crash helpers hold files open). Scoped to the
  # prefix path so other wine prefixes are untouched.
  pkill -9 -f "$PREFIX" 2>/dev/null || true
  sleep 2
fi

echo "==> Deleting $PREFIX"
rm -rf "$PREFIX"

if [ "$PURGE_INSTALLERS" = 1 ] && [ -d "$REPO_DIR/resources/installers" ]; then
  echo "==> Purging downloaded installers in resources/installers/"
  # remove the downloaded payloads but keep the directory itself
  rm -rf "$REPO_DIR/resources/installers"/* 2>/dev/null || true
fi

echo
echo "==> Done. Prefix wiped — clean 'fresh wine' state."
echo "    Rebuild with:  resources/scripts/wine/setup.sh"
echo "    then:          resources/scripts/lightroom/install-lightroom-classic.sh   (or install-creative-cloud.sh)"
