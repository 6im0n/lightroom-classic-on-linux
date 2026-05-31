#!/usr/bin/env bash
# debug-lightroom-classic-ml.sh — capture why AI masking ("ML model not
# loaded") fails on the GPU/DirectML path. Turns on vkd3d-proton warnings so
# we see any D3D12 feature/metacommand DirectML asks for that vkd3d can't do.
#
# Run, trigger object/background detection, quit. Then report
# /tmp/lrc-ml-debug.log (use the grep printed at the end).

set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
rm -f /tmp/lrc-ml-debug.log

LD_PRELOAD= \
DXVK_CONFIG_FILE="$REPO_DIR/wineprefix/dxvk.conf" \
WINEPREFIX="$REPO_DIR/wineprefix" \
WINEARCH=win64 \
WINEDEBUG="err+all,fixme-all" \
VKD3D_DEBUG=warn \
VKD3D_SHADER_DEBUG=warn \
DISPLAY="${DISPLAY:-:0}" \
  "${WINE:-wine}" "C:\\Program Files\\Adobe\\Adobe Lightroom Classic\\Lightroom.exe" "$@" \
  2>/tmp/lrc-ml-debug.log

echo "log: /tmp/lrc-ml-debug.log"
echo "run: grep -iE 'vkd3d.*(err|warn|fail|unsupport|not.*support)|directml|dml|metacommand|FAILED|E_|not loaded' /tmp/lrc-ml-debug.log | grep -ivE 'HEADER|LISTVIEW|TRACKBAR' | tail -50"
