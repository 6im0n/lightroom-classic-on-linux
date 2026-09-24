#!/usr/bin/env bash
# realign-webview2.sh — let wine share Edge WebView2's msedge.dll across processes.
#
# WHY: msedge.dll (~314 MB) ships with 512-byte file alignment. wine can only
# mmap page-aligned sections from the file; otherwise it copies the whole image
# into each process's private memory. WebView2 runs ~10-12 processes (the CC
# installer opens two WebViews), so that alone costs ~3 GB of RAM.
# pe_realign.py rewrites the DLL with 4 KB file alignment: every process then
# maps the same page cache and keeps only ~26 MB private.
#
# Handles every installed runtime version (WebView2 auto-updates into a new
# Application/<version>/ folder), keeps the untouched file as msedge.dll.orig,
# and skips DLLs that are already realigned. Safe to re-run any time WebView2
# is not running.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="${WINEPREFIX:-$REPO_DIR/wineprefix}"
TOOL="$REPO_DIR/resources/scripts/stubs/pe_realign.py"
APPDIR="$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"

shopt -s nullglob
found=0
for dll in "$APPDIR"/*/msedge.dll; do
  found=1
  # FileAlignment lives at optional header + 36 (PE offset at 0x3c, +24).
  falign=$(python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(4096); print(struct.unpack_from("<I",d,struct.unpack_from("<I",d,0x3c)[0]+60)[0])' "$dll")
  if [ "$falign" -ge 4096 ]; then
    echo "==> ${dll#"$APPDIR"/}: already realigned"
    continue
  fi
  cp -p "$dll" "$dll.orig"
  python3 "$TOOL" "$dll.orig" "$dll.new"
  mv -f "$dll.new" "$dll"
done

if [ "$found" = 0 ]; then
  echo "==> No WebView2 runtime found under $APPDIR (nothing to realign)"
else
  echo "==> WebView2 msedge.dll realigned (shared across processes)"
fi
