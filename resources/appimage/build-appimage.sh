#!/usr/bin/env bash
# build-appimage.sh — build the Lightroom Classic on Linux AppImage.
#
#   resources/appimage/build-appimage.sh [--out DIR] [--keep-appdir] [--no-update-info]
#
# Output: DIR/Lightroom_Classic_on_Linux-<version>-x86_64.AppImage (+ .zsync)
# (DIR defaults to build/ in the repo, which is git-ignored).
#
# Steps:
#   1. app/   the repo's tracked start.sh, docs and resources/{scripts,stubs,patches},
#             working-tree content (uncommitted edits included; a warning says so)
#   2. deps/  pinned wine, DXVK, vkd3d-proton, winetricks, gecko (fetch-deps.sh),
#             minus wine's headers, import libs, man pages and dev tools
#   3. AppRun, usr/bin/winetricks (the pinning wrapper), .desktop, icon, bundle-id
#   4. appimagetool + runtime, both pinned in deps.lock, pack it
#
# Nothing is downloaded that isn't in deps.lock, and every download is
# sha256-checked. Adobe software is never bundled: the AppImage installs it
# into the user's prefix at first run.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$HERE/../.." && pwd)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lightroom-classic-on-linux/appimage-downloads"

OUT="$REPO_DIR/build"
KEEP_APPDIR=0
UPDATE_INFO=1
while [ $# -gt 0 ]; do
  case "$1" in
    --out)            OUT=$2; shift ;;
    --out=*)          OUT=${1#*=} ;;
    --keep-appdir)    KEEP_APPDIR=1 ;;
    --no-update-info) UPDATE_INFO=0 ;;
    -h|--help)        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

for tool in git curl sha256sum tar zstd xz; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done

# shellcheck source=deps.lock
. "$HERE/deps.lock"

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
    rm -f "$dest.part"; exit 1
  fi
  mv -f "$dest.part" "$dest"
  echo "$dest"
}

cd "$REPO_DIR"
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
NAME="Lightroom_Classic_on_Linux-$VERSION-x86_64.AppImage"
APPDIR="$OUT/AppDir"

if [ -n "$(git status --porcelain -- start.sh resources/scripts resources/stubs resources/patches)" ]; then
  echo "WARN: uncommitted changes in the bundled files — building them as they are ($VERSION)" >&2
fi

echo "==> Building $NAME"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/app" "$APPDIR/usr/bin"

# ---------------------------------------------------------------------------
# 1. app/ — tracked files only (no wineprefix, installers, logs, screenshots)
# ---------------------------------------------------------------------------
echo "==> Copying the scripts"
git ls-files -z -- start.sh README.md LICENSE DOCS \
    resources/scripts resources/stubs resources/patches |
  xargs -0 cp --parents -a -t "$APPDIR/app/"
# One mtime for everything. build-stubs.sh / install-ai-masking.sh rebuild a
# helper when its source is newer than the shipped binary; a git checkout
# leaves arbitrary mtimes, which could make them try to recompile at first run.
STAMP=$(git log -1 --format=%ct 2>/dev/null || date +%s)
find "$APPDIR/app" -exec touch -h -d "@$STAMP" {} +

# ---------------------------------------------------------------------------
# 2. deps/ — pinned dependencies, trimmed to what runs
# ---------------------------------------------------------------------------
"$HERE/fetch-deps.sh" "$APPDIR/deps"
W="$APPDIR/deps/wine"
echo "==> Trimming wine (headers, import libs, man pages, dev tools)"
rm -rf "$W/include" "$W/share/man" "$W/share/applications"
find "$W/lib" -name '*.a' -delete
for t in function_grep.pl widl winebuild winecpp winedump wineg++ winegcc winemaker wmc wrc; do
  rm -f "$W/bin/$t"
done

# ---------------------------------------------------------------------------
# 3. entry point, wrapper, desktop integration
# ---------------------------------------------------------------------------
install -m 755 "$HERE/AppRun" "$APPDIR/AppRun"
install -m 755 "$HERE/winetricks-wrapper.sh" "$APPDIR/usr/bin/winetricks"

ICON=lightroom-classic-on-linux
cp "$HERE/$ICON.png" "$APPDIR/$ICON.png"
ln -sf "$ICON.png" "$APPDIR/.DirIcon"
cat > "$APPDIR/$ICON.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Lightroom Classic on Linux
Comment=Install and run Adobe Lightroom Classic under a pinned wine
Exec=AppRun
Icon=$ICON
Terminal=false
Categories=Graphics;Photography;
StartupWMClass=lightroom.exe
X-AppImage-Version=$VERSION
EOF

# AppRun re-copies app/ into the user's data dir when this changes. Content
# hash, not just the git version, so a -dirty rebuild is picked up too.
{ echo "$VERSION"
  (cd "$APPDIR/app" && find . -type f -print0 | sort -z | xargs -0 cat; cat "$HERE/deps.lock") |
    sha256sum | cut -d' ' -f1
} | paste -sd' ' > "$APPDIR/bundle-id"

# ---------------------------------------------------------------------------
# 4. pack
# ---------------------------------------------------------------------------
APPIMAGETOOL=$(download "$APPIMAGETOOL_URL" "$APPIMAGETOOL_SHA256")
RUNTIME=$(download "$RUNTIME_URL" "$RUNTIME_SHA256")
chmod +x "$APPIMAGETOOL"

args=(--runtime-file "$RUNTIME" --comp zstd)
if [ "$UPDATE_INFO" = 1 ]; then
  # Lets AppImageUpdate / Gear Lever fetch only the changed blocks of a newer
  # release from GitHub (needs the .zsync file uploaded next to the AppImage).
  args+=(-u "gh-releases-zsync|6im0n|lightroom-classic-on-linux|latest|Lightroom_Classic_on_Linux-*x86_64.AppImage.zsync")
fi

echo "==> Packing (appimagetool $APPIMAGETOOL_VERSION, runtime $RUNTIME_VERSION)"
mkdir -p "$OUT"
rm -f "$OUT/$NAME" "$OUT/$NAME.zsync"
# Extract-and-run: works without FUSE (containers, CI).
( cd "$OUT" && ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL" "${args[@]}" "$APPDIR" "$OUT/$NAME" )

[ "$KEEP_APPDIR" = 1 ] || rm -rf "$APPDIR"

echo
echo "==> Built $OUT/$NAME ($(du -h "$OUT/$NAME" | cut -f1))"
[ -f "$OUT/$NAME.zsync" ] && echo "    update file: $OUT/$NAME.zsync"
echo "    run it:  chmod +x \"$OUT/$NAME\" && \"$OUT/$NAME\""
