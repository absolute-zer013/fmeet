#!/usr/bin/env bash
# Launch the release build. Pass `x11` to force GTK onto XWayland — a cheap
# experiment for the field crash (the Dart UI isolate SIGSEGV on this
# Wayland/radeonsi/Mesa box). Native Wayland is the default.
#
#   tool/run-release.sh         # native Wayland
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

if [[ "${1:-}" == "x11" ]]; then
  echo "launching with GDK_BACKEND=x11 (XWayland)"
  export GDK_BACKEND=x11
fi

echo "log: ${XDG_RUNTIME_DIR:-/tmp}/pixyctl.log"
exec "$BIN"
