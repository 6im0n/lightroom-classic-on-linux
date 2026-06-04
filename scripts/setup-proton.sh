#!/usr/bin/env bash
# setup-proton.sh — prepare the GE-Proton prefix (wineprefix-proton/).
#
# GE-Proton already bundles DXVK + vkd3d-proton + media-foundation (mfplat) +
# fsync, so this is much lighter than the system-wine setup.sh: no dxvk verb, no
# vkd3d copy, no patched mfplat. We just create the prefix, set the Windows
# version, install the few runtimes Adobe needs, write the DXVK config, and drop
# the hnetcfg stub that Lightroom Classic loads.
#
# Run it through ./start.sh (Proton route) or directly. Needs umu-launcher.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proton-common.sh"

proton_preflight || exit 1

echo "==> [proton] GE-Proton prefix: $PFX"
echo "==> [proton] PROTONPATH=$PROTONPATH (umu auto-downloads GE-Proton if needed)"

# 1. Bootstrap the prefix (first umu-run creates + initialises it).
echo "==> [proton] Bootstrapping prefix (first run downloads GE-Proton — be patient)"
uwine wineboot --init || true

# Find the real drive_c (umu/Proton may nest it under pfx/).
DRIVE_C=$(find "$PFX" -maxdepth 3 -type d -name drive_c 2>/dev/null | head -n1)
if [ -z "$DRIVE_C" ]; then
  echo "ERROR: prefix didn't initialise (no drive_c under $PFX). Is umu-run working?"
  exit 1
fi
SYS32="$DRIVE_C/windows/system32"
echo "==> [proton] drive_c: $DRIVE_C"

# 2. Windows version (Adobe OS check). win10 = passes + no win11 Mica flicker.
pset_winver "${PROTON_WINVER:-win10}"

# 3. Runtimes Adobe needs (GE-Proton already has DXVK/vkd3d/mfplat/fonts core).
VERBS_MARKER="$PFX/.setup-proton-verbs-done"
if [ ! -f "$VERBS_MARKER" ]; then
  echo "==> [proton] Installing winetricks verbs (corefonts vcrun2022 ucrtbase2019)"
  urun winetricks -q corefonts vcrun2022 ucrtbase2019 || true
  touch "$VERBS_MARKER"
else
  echo "==> [proton] verbs already installed"
fi

# 4. DXVK config — the dummy composition swapchain so CC's WebView2/Electron UI
#    paints (GE-Proton's DXVK honours DXVK_CONFIG_FILE just like system DXVK).
DXVK_CONF="$PFX/dxvk.conf"
if [ ! -f "$DXVK_CONF" ]; then
  echo "==> [proton] Writing $DXVK_CONF"
  cat > "$DXVK_CONF" <<'EOF'
dxgi.enableDummyCompositionSwapchain = True
EOF
fi

# 5. Adobe NLA "online" registry fix.
echo "==> [proton] Applying NLA active-probing keys"
uwine reg add 'HKLM\System\CurrentControlSet\Services\NlaSvc\Parameters\Internet' \
  /v EnableActiveProbing /t REG_DWORD /d 1 /f >/dev/null 2>&1 || true

# 6. hnetcfg stub (Lightroom Classic does an in-process COM load of hnetcfg.dll).
"$REPO_DIR/scripts/build-stubs.sh" || true
if [ -f "$REPO_DIR/stubs/binaries/hnetcfg-stub.dll" ]; then
  mkdir -p "$SYS32"
  cp -v "$REPO_DIR/stubs/binaries/hnetcfg-stub.dll" "$SYS32/hnetcfg.dll"
  uwine reg add 'HKCU\Software\Wine\DllOverrides' /v hnetcfg /t REG_SZ /d "native,builtin" /f >/dev/null 2>&1 || true
fi

echo
echo "==> setup-proton.sh complete."
echo "    Install Lightroom Classic:"
echo "      scripts/install-creative-cloud-proton.sh   (CC route)"
echo "      — or the standalone Set-up.exe via umu (see GUIDE)."
echo "    Run apps:"
echo "      scripts/run-lightroom-classic-proton.sh"
echo "      scripts/run-creative-cloud-proton.sh"
