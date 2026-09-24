#!/usr/bin/env bash
# Build the WebView2 dcomp.dll from the exact Wine 11.10 source revision.
#
# The patch is wine-staging v11.10's dcomp patchset (dlls/dcomp only), i.e.
# WITHOUT staging 11.11+'s "Allow IDCompositionDevice3" change, which makes the
# Edge WebView2 gpu-process crash-loop and eat all RAM (see the patch header).
#
# Shares the Wine checkout and build directory with build-d2d1-lightroom.sh:
#
#   resources/scripts/wine/build-dcomp-webview2.sh
#   resources/scripts/wine/build-dcomp-webview2.sh --install
#
# --install copies it into system32 and sets dcomp=native for
# msedgewebview2.exe ONLY; every other program keeps wine's builtin dcomp.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PATCH="$REPO_DIR/resources/patches/wine/dcomp-webview2.patch"
OUTPUT="$REPO_DIR/resources/stubs/binaries/dcomp-webview2.dll"
PREFIX="${WINEPREFIX:-$REPO_DIR/wineprefix}"

WINE_TAG=wine-11.10
WINE_COMMIT=2cac6ccf33c0807f374dc96f5a20e35a2da86157
SOURCE_DIR="${WINE_SOURCE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/lightroom-classic-on-linux/$WINE_TAG}"
BUILD_DIR="${WINE_BUILD_DIR:-}"
INSTALL=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Options:
  --source-dir DIR  Reuse or create a Wine source checkout at DIR.
  --build-dir DIR   Use DIR as the out-of-tree Wine build directory.
  --output FILE     Write the native-loadable dcomp.dll to FILE.
  --install         Also install the DLL into \$WINEPREFIX (WebView2 only).
  -h, --help        Show this help.

Environment:
  WINE_SOURCE_DIR, WINE_BUILD_DIR, WINEPREFIX, WINE, JOBS
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: --source-dir needs a path" >&2; exit 2; }
      SOURCE_DIR=$2
      shift 2
      ;;
    --build-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: --build-dir needs a path" >&2; exit 2; }
      BUILD_DIR=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || { echo "ERROR: --output needs a path" >&2; exit 2; }
      OUTPUT=$2
      shift 2
      ;;
    --install)
      INSTALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/build-lightroom}"

for tool in git make python3 x86_64-w64-mingw32-gcc flex bison; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: required build tool not found: $tool" >&2
    exit 1
  }
done

if [ ! -f "$PATCH" ]; then
  echo "ERROR: patch not found: $PATCH" >&2
  exit 1
fi

if [ ! -d "$SOURCE_DIR/.git" ]; then
  if [ -e "$SOURCE_DIR" ]; then
    echo "ERROR: $SOURCE_DIR exists but is not a git checkout" >&2
    exit 1
  fi
  echo "==> Cloning Wine $WINE_TAG into $SOURCE_DIR"
  mkdir -p "$(dirname "$SOURCE_DIR")"
  git clone --depth 1 --branch "$WINE_TAG" --single-branch \
    https://github.com/wine-mirror/wine.git "$SOURCE_DIR"
fi

actual_commit=$(git -C "$SOURCE_DIR" rev-parse HEAD)
if [ "$actual_commit" != "$WINE_COMMIT" ]; then
  echo "ERROR: Wine source is at $actual_commit" >&2
  echo "       expected $WINE_COMMIT ($WINE_TAG)" >&2
  exit 1
fi

if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  echo "==> WebView2 dcomp patch already applied"
elif git -C "$SOURCE_DIR" apply --check "$PATCH" >/dev/null 2>&1; then
  echo "==> Applying WebView2 dcomp patch"
  git -C "$SOURCE_DIR" apply "$PATCH"
else
  echo "ERROR: the dcomp patch neither applies cleanly nor matches the checkout" >&2
  echo "       use a clean Wine $WINE_TAG checkout" >&2
  exit 1
fi

# The patch adds source files to dlls/dcomp/Makefile.in, so the generated
# top-level Makefile must be refreshed whenever that file is newer.
mkdir -p "$BUILD_DIR"
if [ ! -f "$BUILD_DIR/Makefile" ] ||
   [ "$SOURCE_DIR/dlls/dcomp/Makefile.in" -nt "$BUILD_DIR/Makefile" ]; then
  echo "==> Configuring the minimal 64-bit Wine build"
  (
    cd "$BUILD_DIR"
    "$SOURCE_DIR/configure" --enable-archs=x86_64 --without-x --without-freetype
  )
fi

echo "==> Building Wine tools and dcomp.dll"
make -C "$BUILD_DIR" -j"${JOBS:-$(nproc)}" __tooldeps__
make -C "$BUILD_DIR" -j"${JOBS:-$(nproc)}" dlls/dcomp/x86_64-windows/dcomp.dll

built_dll="$BUILD_DIR/dlls/dcomp/x86_64-windows/dcomp.dll"
if [ ! -f "$built_dll" ]; then
  echo "ERROR: build completed without producing $built_dll" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
tmp_output=$(mktemp "$(dirname "$OUTPUT")/.dcomp-webview2.XXXXXX.dll")
trap 'rm -f "$tmp_output"' EXIT

# Wine-built PE DLLs contain "Wine builtin DLL" at offset 0x40. Native DLL
# overrides reject that marker, so clear it in the distributable copy.
python3 - "$built_dll" "$tmp_output" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
data = bytearray(source.read_bytes())
marker = b"Wine builtin DLL"
offset = data.find(marker)

if offset != 0x40:
    raise SystemExit(f"unexpected Wine builtin marker offset: {offset:#x}")

data[offset:offset + len(marker)] = b"\0" * len(marker)
output.write_bytes(data)
print(f"    cleared native-load marker at {offset:#x}; {len(data)} bytes")
PY

chmod 0644 "$tmp_output"
mv -f "$tmp_output" "$OUTPUT"
trap - EXIT
echo "==> Wrote $OUTPUT"
sha256sum "$OUTPUT"

if [ "$INSTALL" -eq 1 ]; then
  "$REPO_DIR/resources/scripts/wine/install-dcomp-webview2.sh"
fi
