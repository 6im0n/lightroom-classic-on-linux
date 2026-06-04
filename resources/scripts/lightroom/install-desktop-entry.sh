#!/usr/bin/env bash
# install-desktop-entry.sh — install a freedesktop launcher for Adobe Lightroom
# Classic so it starts from your desktop's application menu (any DE: KDE, LXDE,
# XFCE, GNOME...) and goes through run-lightroom-classic.sh — i.e. with all our
# fixes (HiDPI scale, X11 driver, MIT-SHM crash fix, AI masking).
#
# Why this exists: wine's winemenubuilder auto-generates an entry that calls
# Lightroom.exe *raw* and hard-codes the prefix path it saw at install time. If
# the repo moved (e.g. Downloads -> Project) that path is stale and the launcher
# does nothing; even when the path is right, it skips every fix. This script
# replaces that entry with one that points at the run script in THIS repo.
#
# Options (flags; sensible defaults if omitted):
#   --dpi=N           UI scale as a wine LogPixels value (96 = 100%). Passed to
#                     the run script as --dpi=N. Omit -> launcher default (144).
#   --vdesktop[=WxH]  launch inside a wine virtual desktop (X_CopyArea crash
#                     fallback). Omit -> normal windowed launch.
#   --remove          remove the launcher this script installs and exit.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN_SCRIPT="$REPO_DIR/resources/scripts/lightroom/run-lightroom-classic.sh"

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APPS_DIR/adobe-lightroom-classic.desktop"
# wine's auto-generated entry — broken (stale path, raw exe). Remove it so the
# grid shows one working launcher instead of two same-named entries.
WINE_ENTRY="$APPS_DIR/wine/Programs/Adobe Lightroom Classic.desktop"

DPI=""
VDESKTOP=""
REMOVE=0
for a in "$@"; do
  case "$a" in
    --dpi=*)      DPI="${a#*=}" ;;
    --vdesktop)   VDESKTOP="--vdesktop" ;;
    --vdesktop=*) VDESKTOP="--vdesktop=${a#*=}" ;;
    --remove)     REMOVE=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

if [ "$REMOVE" = 1 ]; then
  rm -f "$DESKTOP_FILE" && echo "removed $DESKTOP_FILE"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
  exit 0
fi

if [ ! -x "$RUN_SCRIPT" ]; then
  echo "run script not found / not executable: $RUN_SCRIPT" >&2
  exit 1
fi

# Build the Exec line: absolute run script + chosen flags.
EXEC="$RUN_SCRIPT"
[ -n "$DPI" ]      && EXEC="$EXEC --dpi=$DPI"
[ -n "$VDESKTOP" ] && EXEC="$EXEC $VDESKTOP"

# Icon — portable across distros / desktops (KDE, LXDE, XFCE, GNOME...).
#
# wine extracts proper square multi-res Lightroom icons into the hicolor theme,
# but names them with a per-install hash (e.g. B61B_Lightroom.0) we can't rely
# on elsewhere. So harvest whatever *Lightroom* icons exist into a STABLE name
# ('adobe-lightroom-classic') in each size dir, then reference that name. Every
# freedesktop-compliant DE resolves it the same way. If wine extracted nothing
# (icons not yet built on this machine), fall back to the in-repo PNG by path.
ICON_THEME="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
ICON="adobe-lightroom-classic"
_harvested=0
if compgen -G "$ICON_THEME"/*/apps/*[Ll]ightroom*.png >/dev/null 2>&1; then
  for src in "$ICON_THEME"/*/apps/*[Ll]ightroom*.png; do
    sizedir=$(dirname "$src")          # .../hicolor/48x48/apps
    cp -f "$src" "$sizedir/$ICON.png" && _harvested=1
  done
fi
if [ "$_harvested" = 0 ]; then
  # No theme icons to harvest — point straight at the repo PNG (absolute paths
  # in Icon= are valid per the freedesktop spec and work in every DE).
  ICON="$REPO_DIR/resources/installers/lightroom/resources/content/images/appIcon2x.png"
fi

mkdir -p "$APPS_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Adobe Lightroom Classic
Comment=Launch Lightroom Classic under wine with the project's fixes
Exec=$EXEC
Type=Application
StartupNotify=true
Icon=$ICON
StartupWMClass=lightroom.exe
Categories=Graphics;Photography;
EOF
chmod 644 "$DESKTOP_FILE"

# Drop the broken wine-generated duplicate (it may reappear after a wine run;
# re-run this script if so).
if [ -f "$WINE_ENTRY" ]; then
  rm -f "$WINE_ENTRY" && echo "removed broken wine entry: $WINE_ENTRY"
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache  >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f "$ICON_THEME" 2>/dev/null || true

echo "installed launcher: $DESKTOP_FILE"
echo "  Exec = $EXEC"
echo "It should appear in your application menu as 'Adobe Lightroom Classic' (may take a moment)."
