#!/usr/bin/env bash
# Launch the release build.
#
# Default: hardware GL on native Wayland (smooth, no flicker).
#
# Fallback: on some radeonsi/Mesa stacks Flutter's GL texture upload SIGSEGVs
# during the live MJPEG preview (cross-context texture upload -> libgallium). If
# that happens, run `software` to force the llvmpipe software rasterizer (crash-
# safe) plus the XWayland backend (software GL flickers under native Wayland but
# is clean through XWayland). See linux/runner/main.cc and the DEVLOG.
#
#   tool/run-release.sh            # hardware GL, native Wayland (default)
#   tool/run-release.sh software   # software GL + XWayland (PIXY_SOFTWARE=1), crash-safe
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
  software)
    echo "launching with software GL + XWayland (PIXY_SOFTWARE=1)"
    export PIXY_SOFTWARE=1
    ;;
esac

echo "log: ${XDG_RUNTIME_DIR:-/tmp}/pixyctl.log"
exec "$BIN"
