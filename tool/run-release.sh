#!/usr/bin/env bash
# Launch the release build.
#
# The field SIGSEGV was the radeonsi/Mesa GL driver crashing during Flutter's
# cross-context texture upload (live MJPEG preview frames -> GL texture). The
# runner now forces the llvmpipe software rasterizer by default, which avoids
# the broken driver path. See linux/runner/main.cc.
#
#   tool/run-release.sh         # software GL (default, crash-safe)
#   tool/run-release.sh gpu     # opt into hardware GL (PIXY_GPU=1) — may crash
#                               # on radeonsi; fine on stable GPU/driver stacks
#   tool/run-release.sh x11     # force GDK_BACKEND=x11 (XWayland)
#
# Breadcrumbs are written to $XDG_RUNTIME_DIR/pixyctl.log — send the tail after
# a crash. Confirm a new core with: coredumpctl list | grep release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/fmeet"

if [[ ! -x "$BIN" ]]; then
  echo "release binary not found — run: flutter build linux --release" >&2
  exit 1
fi

case "${1:-}" in
  gpu)
    echo "launching with hardware GL (PIXY_GPU=1)"
    export PIXY_GPU=1
    ;;
  x11)
    echo "launching with GDK_BACKEND=x11 (XWayland)"
    export GDK_BACKEND=x11
    ;;
esac

echo "log: ${XDG_RUNTIME_DIR:-/tmp}/pixyctl.log"
exec "$BIN"
