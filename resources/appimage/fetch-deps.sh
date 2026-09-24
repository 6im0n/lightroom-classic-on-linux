#!/usr/bin/env bash
# fetch-deps.sh — download the dependencies pinned in deps.lock into an AppDir.
#
# Build-time only: the AppImage build runs this to fill <AppDir>/deps; the
# repo's normal scripts never call it and keep using the wine on your PATH.
#
#   resources/appimage/fetch-deps.sh <out-dir>     e.g. build/AppDir/deps
#
# Result (one pinned version of each, no version in the dir names so AppRun
# can use fixed paths):
#   <out-dir>/wine/            Kron4ek wine (bin/wine, bin/wineserver, lib/wine/…)
#   <out-dir>/dxvk/            x64/ + x32/ DLLs
#   <out-dir>/vkd3d-proton/    x64/ + x86/ DLLs
#   <out-dir>/winetricks/winetricks
#   <out-dir>/gecko/           wine-gecko x86_64 + x86 MSIs
#   <out-dir>/deps.lock        copy of the lock the bundle was built from
#
# Downloads are cached in ~/.cache/lightroom-classic-on-linux/appimage-downloads
# and every file is checked against its sha256 before use; a mismatch aborts.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCK="$HERE/deps.lock"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lightroom-classic-on-linux/appimage-downloads"

if [ $# -ne 1 ]; then
  echo "usage: $0 <out-dir>" >&2; exit 2
fi
OUT=$1

for tool in curl sha256sum tar zstd xz; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done

# shellcheck source=deps.lock
. "$LOCK"

# download <url> <sha256> — fetch into the cache once, verify, print the path.
download() {
  local url=$1 sha=$2 dest="$CACHE/${1##*/}"
  if [ -f "$dest" ] && echo "$sha  $dest" | sha256sum -c --status; then
    echo "$dest"; return
  fi
  mkdir -p "$CACHE"
  echo "==> Downloading ${url##*/}" >&2
  curl -fL -# --retry 3 -o "$dest.part" "$url"
  if ! echo "$sha  $dest.part" | sha256sum -c --status; then
    echo "ERROR: sha256 mismatch for ${url##*/}" >&2
    echo "  expected $sha" >&2
    echo "  got      $(sha256sum "$dest.part" | cut -d' ' -f1)" >&2
    rm -f "$dest.part"; exit 1
  fi
  mv -f "$dest.part" "$dest"
  echo "$dest"
}

# unpack <archive> <dir> — extract without the archive's top-level folder.
unpack() {
  rm -rf "$2"; mkdir -p "$2"
  case "$1" in
    *.tar.zst) tar --zstd -xf "$1" -C "$2" --strip-components=1 ;;
    *)         tar -xf "$1" -C "$2" --strip-components=1 ;;
  esac
}

mkdir -p "$OUT"

echo "==> wine $WINE_VERSION"
unpack "$(download "$WINE_URL" "$WINE_SHA256")" "$OUT/wine"

echo "==> DXVK $DXVK_VERSION"
unpack "$(download "$DXVK_URL" "$DXVK_SHA256")" "$OUT/dxvk"

echo "==> vkd3d-proton $VKD3D_PROTON_VERSION"
unpack "$(download "$VKD3D_PROTON_URL" "$VKD3D_PROTON_SHA256")" "$OUT/vkd3d-proton"

echo "==> winetricks $WINETRICKS_VERSION"
mkdir -p "$OUT/winetricks"
install -m 755 "$(download "$WINETRICKS_URL" "$WINETRICKS_SHA256")" "$OUT/winetricks/winetricks"

echo "==> Wine Gecko $GECKO_VERSION"
rm -rf "$OUT/gecko"; mkdir -p "$OUT/gecko"
cp "$(download "$GECKO_X86_64_URL" "$GECKO_X86_64_SHA256")" "$OUT/gecko/"
cp "$(download "$GECKO_X86_URL" "$GECKO_X86_SHA256")" "$OUT/gecko/"

cp "$LOCK" "$OUT/deps.lock"

echo "==> Pinned dependencies ready in $OUT"
"$OUT/wine/bin/wine" --version
