#!/usr/bin/env bash
# Launch the release build.
#
# The field SIGSEGV was the radeonsi/Mesa GL driver crashing during Flutter's
# cross-context texture upload (live MJPEG preview frames -> GL texture). The
# runner forces the llvmpipe software rasterizer by default, which avoids the
# broken driver path. Software GL flickers under native Wayland, so the runner
# also defaults to the XWayland (x11) backend in software mode. See
# linux/runner/main.cc.
#
#   tool/run-release.sh         # software GL + XWayland (default: no crash, no flicker)
#   tool/run-release.sh gpu     # hardware GL on native Wayland (PIXY_GPU=1) — may
#                               # crash on radeonsi; fine on stable GPU/driver stacks
#   tool/run-release.sh wayland # software GL but stay on native Wayland (PIXY_WAYLAND=1)
#                               # — accepts the software-GL flicker
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
    echo "launching with hardware GL on native Wayland (PIXY_GPU=1)"
    export PIXY_GPU=1
    ;;
  wayland)
    echo "launching with software GL on native Wayland (PIXY_WAYLAND=1)"
    export PIXY_WAYLAND=1
    ;;
esac

echo "log: ${XDG_RUNTIME_DIR:-/tmp}/pixyctl.log"
exec "$BIN"
