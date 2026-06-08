#!/usr/bin/env bash
# Install a per-user application-menu shortcut for the release build, so
# PixyControl launches from the desktop's app menu instead of a terminal.
#
#   packaging/install-desktop.sh            # install / refresh
#   packaging/install-desktop.sh --uninstall
#
# Points Exec at the release bundle in this checkout (absolute path), so a
# rebuild in place keeps working. Re-run after moving the project.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/fmeet"

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
DESKTOP="$APPS_DIR/pixy-control.desktop"
ICON="$ICON_DIR/pixy-control.png"

refresh() {
  update-desktop-database "$APPS_DIR" 2>/dev/null || true
  gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$DESKTOP" "$ICON"
  refresh
  echo "removed PixyControl menu entry"
  exit 0
fi

if [[ ! -x "$BIN" ]]; then
  echo "release binary not found at $BIN" >&2
  echo "build it first: (fvm) flutter build linux --release" >&2
  exit 1
fi

mkdir -p "$APPS_DIR" "$ICON_DIR"

# Branded icon: blue rounded square + a white camcorder glyph. Falls back to the
# stock 'camera-web' icon name if ImageMagick isn't installed.
ICON_NAME="pixy-control"
if command -v magick >/dev/null 2>&1; then
  magick -size 256x256 xc:none \
    -fill "#3B6EF6" -draw "roundrectangle 0,0 255,255 48,48" \
    -fill white \
    -draw "roundrectangle 48,98 162,182 16,16" \
    -draw "polygon 168,120 212,98 212,182 168,160" \
    "$ICON"
elif convert -list format >/dev/null 2>&1; then
  convert -size 256x256 xc:none \
    -fill "#3B6EF6" -draw "roundrectangle 0,0 255,255 48,48" \
    -fill white \
    -draw "roundrectangle 48,98 162,182 16,16" \
    -draw "polygon 168,120 212,98 212,182 168,160" \
    "$ICON"
else
  ICON_NAME="camera-web"  # stock freedesktop icon
fi

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=PixyControl
GenericName=EMEET PIXY Camera Control
Comment=Native Linux control for the EMEET PIXY AI PTZ webcam
Exec=$BIN
Icon=$ICON_NAME
Terminal=false
Categories=AudioVideo;
Keywords=webcam;camera;ptz;emeet;pixy;
StartupWMClass=com.fmeet.fmeet
EOF

chmod +x "$DESKTOP"
refresh
echo "installed: $DESKTOP"
echo "  Exec = $BIN"
echo "  Icon = $ICON_NAME"
echo "Search 'PixyControl' in your app menu (may need a re-login on some shells)."
