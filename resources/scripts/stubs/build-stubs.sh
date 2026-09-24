#!/usr/bin/env bash
# build-stubs.sh — compile the stub DLLs with mingw-w64.
#
# Outputs to resources/stubs/binaries/:
#   hnetcfg-stub.dll
#
# Idempotent: a .dll is rebuilt only when it's missing or a source was edited
# after it was built. On a fresh clone the shipped binaries count as up to date.
#
# Prereqs: x86_64-w64-mingw32-gcc on PATH, but only when something has to be
# built. Without it, existing binaries are used as they are (with a warning if
# a source is newer).
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

have_cc() { command -v "$CC" >/dev/null 2>&1; }

# stale OUT SRC... : true when OUT is missing or a source is newer than it.
# Compared in whole seconds with 5 s of slack: a git clone writes binaries/
# a few milliseconds before sources/, which must not count as "source edited".
stale() {
  local out=$1; shift
  [ -f "$out" ] || return 0
  local src out_t
  out_t=$(stat -c %Y "$out")
  for src in "$@"; do
    [ "$(stat -c %Y "$src")" -gt $((out_t + 5)) ] && return 0
  done
  return 1
}

# can_build OUT : true if we should compile OUT now. Without a compiler, keep an
# existing binary (warn) and fail only when there is nothing to fall back on.
can_build() {
  local out=$1
  have_cc && return 0
  if [ -f "$out" ]; then
    echo "WARN: $CC not found; keeping the shipped $(basename "$out") (its source is newer)."
    return 1
  fi
  echo "ERROR: $(basename "$out") is missing and $CC is not on PATH."
  echo "  Ubuntu/Debian: sudo apt install mingw-w64"
  echo "  Fedora:        sudo dnf install mingw64-gcc"
  echo "  Arch:          sudo pacman -S mingw-w64-gcc"
  exit 1
}

build() {
  local src=$1 out=$2
  local libs=$3
  if [ ! -f "$SRC_DIR/$src" ]; then
    echo "ERROR: $SRC_DIR/$src not found"; exit 1
  fi
  if ! stale "$OUT_DIR/$out" "$SRC_DIR/$src"; then
    echo "==> $out is up to date"
    return
  fi
  can_build "$OUT_DIR/$out" || return 0
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
if ! stale "$PROXY_OUT" "$PROXY_SRC" "$PROXY_DEF"; then
  echo "==> version-proxy.dll is up to date"
elif can_build "$PROXY_OUT"; then
  echo "==> Building version-proxy.dll from fix_ghost.c + version-proxy.def"
  $CC -shared -Wl,--kill-at -O2 -s -o "$PROXY_OUT" "$PROXY_SRC" "$PROXY_DEF" -luser32 -lgdi32
fi

echo
echo "==> build-stubs.sh done. Binaries in $OUT_DIR"
ls -la "$OUT_DIR"
