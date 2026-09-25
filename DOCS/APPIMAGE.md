# AppImage

The AppImage is one file that holds everything needed to install and run
Lightroom Classic: the scripts from this repo, plus a wine, DXVK,
vkd3d-proton and winetricks at versions that are known to work. You don't
install wine from your distro, and a distro update can't break your setup.

Lightroom itself is not inside. You install it on first run with your own
Adobe account, the same way as with the repo.

## Use it

```bash
chmod +x Lightroom_Classic_on_Linux-*.AppImage
./Lightroom_Classic_on_Linux-*.AppImage
```

The first time, a setup menu opens in a terminal. It's the same menu as
`./start.sh` in the repo: pick the recommended step each time until Lightroom
is installed. After that, the same file starts Lightroom directly.

It also adds **Lightroom Classic on Linux** to your application menu, with its
icon. Right-click that entry for the setup menu.

### Commands

| Command | What it does |
|---|---|
| *(nothing)* | Start Lightroom, or the setup menu if it isn't installed yet |
| `--menu` | Open the setup menu |
| `--cc` | Start the Creative Cloud app |
| `--kill` | Stop everything running in wine (if an app hangs) |
| `--wine …` | Run the bundled wine, e.g. `--wine winecfg` |
| `--winetricks …` | Run the bundled winetricks |
| `--versions` | Show the bundled versions |
| `--remove-menu-entry` | Remove the application menu entry |
| `--help` | Show all of this |

Other options go to Lightroom's launcher, e.g. `--dpi=144` or `--vdesktop`
(see [GUIDE.md](GUIDE.md)).

## How it works

An AppImage is a small program with a compressed, read-only folder attached.
When you start it, that folder is mounted under `/tmp/.mount_…`, and
`AppRun` runs from it. When you close the app, the mount goes away.

```
Lightroom_Classic_on_Linux.AppImage
├── AppRun              the entry point
├── app/                this repo's scripts and docs
├── deps/               wine, DXVK, vkd3d-proton, winetricks, Wine Gecko
└── usr/bin/winetricks  a wrapper that pins DXVK and vkd3d-proton
```

### Your data lives outside

The AppImage can't be written to, and wine needs a writable prefix. So on
start, `AppRun` copies the scripts to:

```
~/.local/share/lightroom-classic-on-linux/
├── wineprefix/         Windows, Lightroom, your settings
├── resources/          scripts + installers you download
└── logs/
```

Set `LR_HOME=/some/where` to use another folder. When you get a newer
AppImage, it refreshes the scripts there. It never touches `wineprefix/`,
your installers or your logs.

### Pinned versions

Every script runs with the bundled wine first in `PATH`, so your distro's wine
is never used. The versions are listed in
[`resources/appimage/deps.lock`](../resources/appimage/deps.lock):

| | Version |
|---|---|
| Wine | 11.18 staging ([Kron4ek build](https://github.com/Kron4ek/Wine-Builds)) |
| DXVK | 3.1.1 |
| vkd3d-proton | 3.0.1 |
| winetricks | 20260125 |
| Wine Gecko | 2.47.4 |

The scripts ask winetricks for DXVK and vkd3d-proton, and winetricks would
install the newest release. The bundled `winetricks` is a wrapper: for those
two it installs the bundled copies instead, and passes everything else to the
real winetricks. When a newer AppImage ships a different DXVK or vkd3d-proton,
`AppRun` updates the prefix on the next start.

### What it needs from your system

- Linux x86_64 with working Vulkan drivers (`vulkaninfo` should list your GPU)
- Normal desktop libraries: X11 or Wayland, fontconfig, freetype, GnuTLS.
  Any regular desktop distro has them.
- FUSE to mount the AppImage. Without it, run it with
  `APPIMAGE_EXTRACT_AND_RUN=1`.

### Remove it

```bash
./Lightroom_Classic_on_Linux-*.AppImage --remove-menu-entry
rm Lightroom_Classic_on_Linux-*.AppImage
rm -rf ~/.local/share/lightroom-classic-on-linux   # deletes Lightroom and its settings
```

## Build it

You need `git`, `curl`, `tar`, `xz` and `zstd`. FUSE isn't needed. From the
repo:

```bash
resources/appimage/build-appimage.sh
```

That's it. After about 20 seconds (longer the first time, while it downloads
about 230 MB) you get:

```
build/Lightroom_Classic_on_Linux-<version>-x86_64.AppImage
build/Lightroom_Classic_on_Linux-<version>-x86_64.AppImage.zsync
```

`<version>` comes from `git describe`, e.g. `v1.2.0`. It ends in `-dirty` if
you have uncommitted changes, which are included in the build.

### What the build does

1. Copies the tracked scripts and docs into `build/AppDir/app/`.
2. Downloads the pinned wine, DXVK, vkd3d-proton, winetricks and Wine Gecko,
   checks each file's sha256, and removes parts of wine that are only needed to
   compile (about 175 MB).
3. Adds `AppRun`, the winetricks wrapper, the icon and the `.desktop` file.
4. Packs it with `appimagetool`. The tool and the AppImage runtime are pinned
   too.

Downloads are kept in `~/.cache/lightroom-classic-on-linux/appimage-downloads`,
so later builds are offline.

### Options

| Option | What it does |
|---|---|
| `--out DIR` | Write to `DIR` instead of `build/` |
| `--keep-appdir` | Keep `build/AppDir` to look inside |
| `--no-update-info` | Don't embed update info and skip the `.zsync` file |

### Publish a release

Upload both the `.AppImage` and the `.zsync` file to a GitHub release. The
update info in the AppImage points at the latest release, so tools like
[Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) or AppImageUpdate
can download only what changed.

### Upgrade a dependency

1. Test the new version (for example with the repo scripts and `WINE=/path/to/wine`).
2. In `resources/appimage/deps.lock`, change its `VERSION`, `URL` and
   `SHA256` together.
3. Rebuild.

A wrong checksum stops the build, so a download can't change without you
noticing.
