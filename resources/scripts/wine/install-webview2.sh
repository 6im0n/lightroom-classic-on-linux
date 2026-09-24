#!/usr/bin/env bash
# install-webview2.sh — install the Microsoft Edge WebView2 runtime into the
# prefix (Adobe's installers draw their UI and sign-in pages with it).
#
# Installer choice, first match wins, both from resources/installers/:
#   1. MicrosoftEdgeWebView2RuntimeInstallerX64.exe — Microsoft's standalone
#      ("offline") runtime installer, ~200 MB. Installs with no network, so it
#      suits prefixes kept offline. Download it from
#      https://developer.microsoft.com/microsoft-edge/webview2/ (Evergreen
#      Standalone Installer, x64).
#   2. MicrosoftEdgeWebview2Setup.exe — the small online bootstrapper; it
#      downloads the runtime at install time. Fetched automatically if absent.
#
# Skips everything when WebView2 is already installed. Idempotent.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="${WINEPREFIX:-$REPO_DIR/wineprefix}"
WINE=${WINE:-wine}
INSTALLERS="$REPO_DIR/resources/installers"
OFFLINE="$INSTALLERS/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
ONLINE="$INSTALLERS/MicrosoftEdgeWebview2Setup.exe"

if [ -d "$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView" ]; then
  echo "==> WebView2 already installed"
  exit 0
fi

if [ -f "$OFFLINE" ]; then
  echo "==> Installing WebView2 runtime (offline standalone installer)"
  installer=$OFFLINE
else
  if [ ! -f "$ONLINE" ]; then
    echo "==> Downloading MicrosoftEdgeWebview2Setup.exe"
    curl -L -o "$ONLINE" "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
  fi
  echo "==> Installing WebView2 runtime (online bootstrapper, needs network)"
  installer=$ONLINE
fi

WINEPREFIX="$PREFIX" "$WINE" "$installer" /silent /install || true

if [ ! -d "$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView" ]; then
  echo "WARN: WebView2 does not look installed after running $(basename "$installer")." >&2
fi
