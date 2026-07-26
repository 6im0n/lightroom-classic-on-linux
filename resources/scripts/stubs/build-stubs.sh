#!/usr/bin/env bash
# build-stubs.sh — compile the stub DLLs with mingw-w64.
#
# Outputs to resources/stubs/binaries/:
#   hnetcfg-stub.dll
#
# Idempotent: if the .dll is newer than its .c source, the build is skipped.
#
# Prereqs: x86_64-w64-mingw32-gcc on PATH.
#   Ubuntu/Debian: sudo apt install mingw-w64
#   Fedora:        sudo dnf install mingw64-gcc
#   Arch:          sudo pacman -S mingw-w64-gcc
# made by: sander110419

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SRC_DIR="$REPO_DIR/resources/stubs/sources"
OUT_DIR="$REPO_DIR/resources/stubs/binaries"

mkdir -p "$OUT_DIR"

CC=${CC:-x86_64-w64-mingw32-gcc}
CFLAGS="-shared -Wl,--kill-at -nostartfiles -O2 -s"

if ! command -v "$CC" >/dev/null 2>&1; then
  echo "ERROR: $CC not found on PATH."
  echo "  Ubuntu/Debian: sudo apt install mingw-w64"
  echo "  Fedora:        sudo dnf install mingw64-gcc"
  echo "  Arch:          sudo pacman -S mingw-w64-gcc"
  exit 1
fi

build() {
  local src=$1 out=$2
  local libs=$3
  if [ ! -f "$SRC_DIR/$src" ]; then
    echo "ERROR: $SRC_DIR/$src not found"; exit 1
  fi
  if [ -f "$OUT_DIR/$out" ] && [ "$OUT_DIR/$out" -nt "$SRC_DIR/$src" ]; then
    echo "==> $out is up to date"
    return
  fi
  echo "==> Building $out from $src"
  $CC $CFLAGS -o "$OUT_DIR/$out" "$SRC_DIR/$src" $libs
}

# hnetcfg is the only stub Lightroom Classic actually loads: it does an
# in-process COM load of hnetcfg.dll (firewall config); the stub returns an
# empty firewall-rules enumerator so the probe succeeds cleanly.
build hnetcfg.c         "hnetcfg-stub.dll"                 "-lkernel32 -lole32 -luuid -ladvapi32 -loleaut32"

# version-proxy: fixes dialog "ghosting"/blank panels (Export preset tree,
# Copy Settings) — a proxy version.dll that forwards version's 16 exports to
# version_orig.dll (a copy of wine's builtin) and installs a coalesced repaint
# hook on Lightroom's UI thread; full story in fix_ghost.c.
# install-lightroom-classic-fixes.sh installs it into Lightroom's app dir,
# scoped to Lightroom.exe via a per-app DllOverride (32-bit helpers unaffected).
# Built WITHOUT -nostartfiles: the CRT entry must run so DllMain installs the hook.
PROXY_SRC="$SRC_DIR/fix_ghost.c"
PROXY_DEF="$SRC_DIR/version-proxy.def"
PROXY_OUT="$OUT_DIR/version-proxy.dll"
if [ -f "$PROXY_OUT" ] && [ "$PROXY_OUT" -nt "$PROXY_SRC" ] && [ "$PROXY_OUT" -nt "$PROXY_DEF" ]; then
  echo "==> version-proxy.dll is up to date"
else
  echo "==> Building version-proxy.dll from fix_ghost.c + version-proxy.def"
  $CC -shared -Wl,--kill-at -O2 -s -o "$PROXY_OUT" "$PROXY_SRC" "$PROXY_DEF" -luser32 -lgdi32
fi

echo
echo "==> build-stubs.sh done. Binaries in $OUT_DIR"
ls -la "$OUT_DIR"
