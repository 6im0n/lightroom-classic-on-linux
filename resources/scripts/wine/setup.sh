#!/usr/bin/env bash
# setup.sh — prepare the wine prefix for Adobe Lightroom Classic.
#
# Idempotent: re-running it is safe — each step detects "already done" and
# skips. It does NOT install Lightroom Classic itself; for that run
# resources/scripts/lightroom/install-lightroom-classic.sh (with the standalone Set-up.exe), then
# resources/scripts/lightroom/install-lightroom-classic-fixes.sh, then resources/scripts/wine/install-vkd3d-proton.sh.
#
# What it does, in order:
#   1. Creates wineprefix/ (WINEARCH=win64, version=win10)
#   2. Installs winetricks verbs: corefonts vcrun2019 ucrtbase2019 msxml6
#      gdiplus dotnet48 atmlib fontsmooth=rgb dxvk
#   3. Installs Wine Gecko 2.47.4 (x86_64 + x86 MSI), patches the
#      MSHTML\2.47.4\GeckoPath registry entry to match disk reality.
#   4. Writes dxvk.conf with dxgi.enableDummyCompositionSwapchain=True.
#   5. Applies adobe-fixes.reg (NLA active probing keys).
#   6. Builds the hnetcfg stub (if not already built), installs it as
#      hnetcfg.dll in system32/, and registers the DllOverride.
#   7. Installs the patched d2d1.dll and mfplat.dll if present in resources/stubs/.
#
# Prereqs (see GUIDE.md section 1):
#   wine 11.8 staging or newer, winetricks 20240105+, mingw-w64, curl, unzip.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PREFIX="$REPO_DIR/wineprefix"
DXVK_CONF="$PREFIX/dxvk.conf"
WINE=${WINE:-wine}
WINETRICKS=${WINETRICKS:-winetricks}

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG=${WINEDEBUG:--all,err+all,fixme-all}

mkdir -p "$REPO_DIR/resources/installers" "$REPO_DIR/resources/stubs/binaries" "$REPO_DIR/wineprefix"

echo "==> Wine: $($WINE --version)"
echo "==> Prefix: $PREFIX"

# ---------------------------------------------------------------------------
# 1. Initial prefix bootstrap
# ---------------------------------------------------------------------------
if [ ! -f "$PREFIX/system.reg" ]; then
  echo "==> Bootstrapping wineprefix (this can take a minute)"
  $WINE wineboot --init
else
  echo "==> Prefix already exists, skipping wineboot"
fi

# NOTE: the Windows version is set to win11 in step 2.5 BELOW, *after* the
# winetricks verbs. It must come after, because `winetricks dotnet48` forces the
# prefix back to Windows 7 during the .NET install and leaves it there — setting
# win11 here (before the verbs) would just get clobbered.

# ---------------------------------------------------------------------------
# 2. Winetricks verbs
# ---------------------------------------------------------------------------
VERBS_DONE_MARKER="$PREFIX/.setup-verbs-done"
if [ ! -f "$VERBS_DONE_MARKER" ]; then
  echo "==> Installing winetricks verbs (this can take 20+ minutes, take a coffee break)"
  $WINETRICKS -q \
    corefonts \
    ucrtbase2019 \
    vcrun2019 \
    msxml6 \
    gdiplus \
    dotnet48 \
    atmlib \
    fontsmooth=rgb \
    dxvk
  touch "$VERBS_DONE_MARKER"
else
  echo "==> Winetricks verbs already installed"
fi

# ---------------------------------------------------------------------------
# 2.5 Windows version = win11  (MUST be after the verbs — dotnet48 resets it)
# ---------------------------------------------------------------------------
# Adobe's installers do a hard OS-version check: the Creative Cloud desktop
# app's ESD requires build >= 10.0.18362 ("upgrade your OS" otherwise) and the
# standalone Set-up.exe also rejects old builds. A fresh prefix — and a prefix
# right after `winetricks dotnet48` — reports Windows 7 (build 7601). win11
# sets build 22000, clearing both. Run unconditionally so re-running setup.sh
# self-heals a clobbered version.
echo "==> Setting Windows version to 11 (build 22000)"
$WINETRICKS -q win11 || true

read_build() {
  $WINE reg QUERY "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion" \
    /v CurrentBuildNumber 2>/dev/null | awk '/CurrentBuildNumber/{print $NF}'
}
_build=$(read_build)

# Fallback: if winetricks didn't take (build still < 18362), write the version
# keys directly. Adobe reads CurrentBuildNumber/CurrentVersion from here.
if ! { [ -n "${_build:-}" ] && [ "$_build" -ge 18362 ] 2>/dev/null; }; then
  echo "==> win11 didn't stick (build=${_build:-?}); writing version keys directly"
  CVKEY="HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion"
  $WINE reg ADD "$CVKEY" /v CurrentVersion           /t REG_SZ    /d "10.0"                  /f >/dev/null 2>&1 || true
  $WINE reg ADD "$CVKEY" /v CurrentBuild             /t REG_SZ    /d "22000"                /f >/dev/null 2>&1 || true
  $WINE reg ADD "$CVKEY" /v CurrentBuildNumber       /t REG_SZ    /d "22000"                /f >/dev/null 2>&1 || true
  $WINE reg ADD "$CVKEY" /v ProductName              /t REG_SZ    /d "Microsoft Windows 11" /f >/dev/null 2>&1 || true
  $WINE reg ADD "$CVKEY" /v CurrentMajorVersionNumber /t REG_DWORD /d 10                     /f >/dev/null 2>&1 || true
  $WINE reg ADD "$CVKEY" /v CurrentMinorVersionNumber /t REG_DWORD /d 0                      /f >/dev/null 2>&1 || true
  # drop any per-prefix winver override so the HKLM build above is authoritative
  $WINE reg DELETE 'HKCU\Software\Wine' /v Version /f >/dev/null 2>&1 || true
  _build=$(read_build)
fi

if [ -n "${_build:-}" ] && [ "$_build" -ge 18362 ] 2>/dev/null; then
  echo "==> Windows build: $_build (>= 18362 OK — Adobe OS check will pass)"
else
  echo "WARN: Windows build is ${_build:-unknown} (< 18362). Adobe's OS check"
  echo "      will fail with 'upgrade your OS'. Try: WINEPREFIX=\"$PREFIX\" winetricks -q win11"
fi

# ---------------------------------------------------------------------------
# 3. Wine Gecko 2.47.4 (both arches)
# ---------------------------------------------------------------------------
GECKO_VER=2.47.4
GECKO_DIR="$REPO_DIR/resources/installers/gecko"
mkdir -p "$GECKO_DIR"

for arch in x86_64 x86; do
  msi="wine-gecko-${GECKO_VER}-${arch}.msi"
  if [ ! -f "$GECKO_DIR/$msi" ]; then
    echo "==> Downloading $msi"
    curl -L -o "$GECKO_DIR/$msi" \
      "https://dl.winehq.org/wine/wine-gecko/${GECKO_VER}/$msi"
  fi
done

GECKO_DONE_MARKER="$PREFIX/.setup-gecko-done"
if [ ! -f "$GECKO_DONE_MARKER" ]; then
  echo "==> Installing Wine Gecko"
  for arch in x86_64 x86; do
    $WINE msiexec /i "$GECKO_DIR/wine-gecko-${GECKO_VER}-${arch}.msi" /qn || true
  done
  # Repair the GeckoPath registry value to match where the MSI actually put the
  # files, PER ARCHITECTURE. This must write two DIFFERENT keys — the old code
  # looped both paths into the same key, so syswow64 (last) clobbered system32,
  # leaving 64-bit MSHTML pointing at the 32-bit Gecko. A 64-bit process (e.g.
  # the Creative Cloud app) then can't load it -> a flood of "Failed to init
  # Gecko, returning CLASS_E_CLASSNOTAVAILABLE" and the app misbehaves/crashes.
  #   64-bit MSHTML  -> HKLM\Software\Wine\MSHTML            -> system32 gecko
  #   32-bit MSHTML  -> HKLM\Software\Wow6432Node\Wine\MSHTML -> syswow64 gecko
  $WINE reg ADD "HKLM\\Software\\Wine\\MSHTML\\${GECKO_VER}" \
    /v GeckoPath /t REG_SZ /d "C:\\windows\\system32\\gecko\\${GECKO_VER}\\wine_gecko\\" /f || true
  $WINE reg ADD "HKLM\\Software\\Wow6432Node\\Wine\\MSHTML\\${GECKO_VER}" \
    /v GeckoPath /t REG_SZ /d "C:\\windows\\syswow64\\gecko\\${GECKO_VER}\\wine_gecko\\" /f || true
  touch "$GECKO_DONE_MARKER"
else
  echo "==> Wine Gecko already installed"
fi

# ---------------------------------------------------------------------------
# 4. DXVK config
# ---------------------------------------------------------------------------
if [ ! -f "$DXVK_CONF" ] || ! grep -q "enableDummyCompositionSwapchain = True" "$DXVK_CONF"; then
  echo "==> Writing $DXVK_CONF"
  cat > "$DXVK_CONF" <<'EOF'
# Adobe CC (Electron + WebView2) calls
# IDXGIFactory2::CreateSwapChainForComposition. DXVK normally returns
# E_NOTIMPL for that path. This option exposes a dummy non-DComp
# swapchain so the renderer proceeds and the UI paints.
dxgi.enableDummyCompositionSwapchain = True
EOF
else
  echo "==> dxvk.conf already configured"
fi

# ---------------------------------------------------------------------------
# 5. Apply Adobe registry fixes (NLA active probing)
# ---------------------------------------------------------------------------
REG_FILE="$REPO_DIR/wineprefix/adobe-fixes.reg"
if [ ! -f "$REG_FILE" ]; then
  echo "==> Writing $REG_FILE"
  cat > "$REG_FILE" <<'EOF'
REGEDIT4

; Force network state to "online" so Adobe CC stops falling back to
; local-server-data (a broken code path under wine).

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\NlaSvc\Parameters\Internet]
"EnableActiveProbing"=dword:00000001
"ActiveDnsProbeHost"="dns.msftncsi.com"
"ActiveDnsProbeContent"="131.107.255.255"
"ActiveWebProbeHost"="www.msftncsi.com"
"ActiveWebProbePath"="/ncsi.txt"
"ActiveWebProbeContent"="Microsoft NCSI"
EOF
fi
echo "==> Importing $REG_FILE"
$WINE reg IMPORT "$(winepath -w "$REG_FILE" 2>/dev/null || echo "$REG_FILE")" || \
  $WINE regedit "$REG_FILE" || true

# ---------------------------------------------------------------------------
# 6. Build & install stub DLLs
# ---------------------------------------------------------------------------
"$REPO_DIR/resources/scripts/stubs/build-stubs.sh"

SYS32="$PREFIX/drive_c/windows/system32"
mkdir -p "$SYS32"

# hnetcfg is the only stub Lightroom Classic loads. It does an in-process COM
# load of hnetcfg.dll (firewall config); the stub returns an empty firewall
# rules enumerator so the probe succeeds. Build output is hnetcfg-stub.dll;
# install it as hnetcfg.dll.
#
# (The CC-era stubs — NDFAPI/wkscli/ext-ms-win-uiacore/thumbcache/
# adobe_e26b366d — were verified unused by Classic via a full +loaddll trace
# and removed. Do not re-add them here.)
if [ -f "$REPO_DIR/resources/stubs/binaries/hnetcfg-stub.dll" ]; then
  cp -v "$REPO_DIR/resources/stubs/binaries/hnetcfg-stub.dll" "$SYS32/hnetcfg.dll"
else
  echo "WARN: $REPO_DIR/resources/stubs/binaries/hnetcfg-stub.dll missing — build-stubs.sh failed?"
fi

$WINE reg ADD 'HKCU\Software\Wine\DllOverrides' /v hnetcfg /t REG_SZ /d "native,builtin" /f || true

# ---------------------------------------------------------------------------
# 7. Patched d2d1.dll and mfplat.dll (optional but recommended for LR)
# ---------------------------------------------------------------------------
for pair in "d2d1-patched.dll:d2d1.dll" "mfplat-patched.dll:mfplat.dll"; do
  src=${pair%%:*}
  dst=${pair##*:}
  if [ -f "$REPO_DIR/resources/stubs/binaries/$src" ]; then
    cp -v "$REPO_DIR/resources/stubs/binaries/$src" "$SYS32/$dst"
    $WINE reg ADD "HKCU\\Software\\Wine\\DllOverrides" \
      /v "${dst%.dll}" /t REG_SZ /d "native" /f || true
  else
    echo "INFO: $REPO_DIR/resources/stubs/binaries/$src not present — skipping (see GUIDE 6.4/6.5)"
  fi
done

# Note: Lightroom Classic does NOT ship its own bundled mfplat.dll (unlike
# Lightroom CC), so the system32 patched copy above is sufficient — no
# per-app mfplat replacement is needed.

# ---------------------------------------------------------------------------
# 8. Disable dead legacy video codecs (Creative Cloud startup stability)
# ---------------------------------------------------------------------------
# wine ships ir50_32.dll (Indeo 5) and iyuv_32.dll (IYUV) and auto-loads them at
# startup when an app enumerates video codecs. They import mfplat.dll on a path
# that doesn't resolve for the 32-bit codecs ("Library mfplat.dll ... not found")
# AND, more importantly, every extra DLL that initialises eats one of wine's
# limited TLS slots. Under the Creative Cloud desktop app's enormous DLL load
# (CEF + the whole Adobe stack) that tips wine into TLS-slot exhaustion
# ("err:module:alloc_tls_slot NtQueryInformationThread failed"), and a thread
# then deadlocks holding the loader lock
# ("err:sync:RtlpWaitForCriticalSection ... blocked by <tid>, retrying (60 sec)")
# — CC's window paints but its panels never finish loading. These codecs are
# useless here (legacy formats, broken mfplat link anyway), so disabling them
# removes the TLS pressure and the startup deadlock. (Re-enable by renaming the
# .disabled files back.)
echo "==> Disabling dead legacy video codecs (ir50_32/iyuv_32) for CC startup stability"
for c in ir50_32.dll iyuv_32.dll; do
  if [ -f "$SYS32/$c" ]; then
    mv "$SYS32/$c" "$SYS32/$c.disabled"
    echo "    disabled: system32/$c"
  fi
done

echo
echo "==> setup.sh complete."
echo "    Next: put the Lightroom Classic installer at resources/installers/lightroom/Set-up.exe"
echo "          then run resources/scripts/lightroom/install-lightroom-classic.sh"
