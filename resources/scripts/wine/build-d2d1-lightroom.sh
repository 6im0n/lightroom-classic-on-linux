#!/usr/bin/env bash
# Build Lightroom's patched d2d1.dll from the exact Wine 11.10 source revision.
#
# The patch provides:
#   - the ColorManagement passthrough needed for Lightroom startup;
#   - opt-in PushLayer geometric-mask clipping for histogram fills.
#
# By default the Wine checkout is cached outside the repository. An existing
# checkout can be reused with --source-dir, which is useful for development:
#
#   resources/scripts/wine/build-d2d1-lightroom.sh --source-dir /tmp/wine-src
#   resources/scripts/wine/build-d2d1-lightroom.sh --source-dir /tmp/wine-src --install

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PATCH="$REPO_DIR/resources/patches/wine/d2d1-lightroom.patch"
OUTPUT="$REPO_DIR/resources/stubs/binaries/d2d1-patched.dll"
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
  --output FILE     Write the native-loadable d2d1.dll to FILE.
  --install         Also install the DLL into \$WINEPREFIX/system32.
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
  echo "==> Lightroom d2d1 patch already applied"
elif git -C "$SOURCE_DIR" apply --check "$PATCH" >/dev/null 2>&1; then
  echo "==> Applying Lightroom d2d1 patch"
  git -C "$SOURCE_DIR" apply "$PATCH"
else
  echo "ERROR: the d2d1 patch neither applies cleanly nor matches the checkout" >&2
  echo "       use a clean Wine $WINE_TAG checkout" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
if [ ! -f "$BUILD_DIR/Makefile" ]; then
  echo "==> Configuring the minimal 64-bit Wine build"
  (
    cd "$BUILD_DIR"
    "$SOURCE_DIR/configure" --enable-archs=x86_64 --without-x --without-freetype
  )
fi

echo "==> Building Wine tools and d2d1.dll"
make -C "$BUILD_DIR" -j"${JOBS:-$(nproc)}" __tooldeps__
make -C "$BUILD_DIR" -j"${JOBS:-$(nproc)}" dlls/d2d1/x86_64-windows/d2d1.dll

built_dll="$BUILD_DIR/dlls/d2d1/x86_64-windows/d2d1.dll"
if [ ! -f "$built_dll" ]; then
  echo "ERROR: build completed without producing $built_dll" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
tmp_output=$(mktemp "$(dirname "$OUTPUT")/.d2d1-patched.XXXXXX.dll")
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
  if pgrep -f '[L]ightroom\.exe$' >/dev/null 2>&1; then
    echo "ERROR: Lightroom is running; close it before installing d2d1.dll" >&2
    exit 1
  fi

  system32="$PREFIX/drive_c/windows/system32"
  if [ ! -d "$system32" ]; then
    echo "ERROR: Wine prefix system32 not found: $system32" >&2
    exit 1
  fi

  install_tmp="$system32/.d2d1.dll.new"
  cp -f "$OUTPUT" "$install_tmp"
  mv -f "$install_tmp" "$system32/d2d1.dll"
  echo "==> Installed $system32/d2d1.dll"

  WINEDEBUG=-all WINEPREFIX="$PREFIX" "${WINE:-wine}" reg ADD \
    'HKCU\Software\Wine\DllOverrides' /v d2d1 /t REG_SZ /d native /f >/dev/null
  echo "==> Set d2d1=native for $PREFIX"
fi
