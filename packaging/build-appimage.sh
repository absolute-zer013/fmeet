#!/usr/bin/env bash
# Build a PixyControl AppImage from a Flutter Linux release bundle.
#
# Prerequisites:
#   - flutter (or fvm) on PATH
#   - appimagetool (https://github.com/AppImage/AppImageKit/releases)
#   - libhidapi + mpv installed on the build host (bundled into the AppDir)
#
# Usage:  packaging/build-appimage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP=pixy-control
BUILD_DIR="build/linux/x64/release/bundle"
APPDIR="build/AppDir"

# Prefer fvm if the project pins a Flutter version.
FLUTTER="flutter"
if [ -x ".fvm/flutter_sdk/bin/flutter" ]; then
  FLUTTER=".fvm/flutter_sdk/bin/flutter"
fi

echo "==> flutter build linux --release"
"$FLUTTER" build linux --release

echo "==> assembling AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# App bundle (executable name is the pubspec `name`: fmeet).
cp -r "$BUILD_DIR/"* "$APPDIR/usr/bin/"
# Provide the expected launcher name.
ln -sf fmeet "$APPDIR/usr/bin/$APP"

# Bundle the HID runtime lib we depend on (best-effort copy).
for lib in \
  /usr/lib/libhidapi-hidraw.so* ; do
  cp -av $lib "$APPDIR/usr/lib/" 2>/dev/null || true
done

# Preview + stream keepalive run the `mpv` BINARY as a subprocess (not libmpv).
# It must be present at runtime. We do NOT bundle mpv (it drags in the whole GL/
# codec stack); declare it as a runtime dependency instead. v4l-utils (v4l2-ctl)
# is likewise required. On Arch/CachyOS:  sudo pacman -S mpv v4l-utils hidapi

# Desktop entry + icon.
cp packaging/pixy-control.desktop "$APPDIR/usr/share/applications/$APP.desktop"
cp packaging/pixy-control.desktop "$APPDIR/$APP.desktop"

# A placeholder icon if none is provided; replace with a real PNG when available.
ICON="$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP.png"
if [ -f "packaging/$APP.png" ]; then
  cp "packaging/$APP.png" "$ICON"
else
  : > "$ICON"  # empty placeholder; appimagetool tolerates it
fi
ln -sf "usr/share/icons/hicolor/256x256/apps/$APP.png" "$APPDIR/$APP.png"

# AppRun launcher.
cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${0}")")"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH:-}"
exec "${HERE}/usr/bin/fmeet" "$@"
EOF
chmod +x "$APPDIR/AppRun"

echo "==> appimagetool"
if command -v appimagetool >/dev/null 2>&1; then
  ARCH=x86_64 appimagetool "$APPDIR" "PixyControl-x86_64.AppImage"
  echo "==> built PixyControl-x86_64.AppImage"
else
  echo "appimagetool not found — AppDir is ready at $APPDIR"
  echo "Install appimagetool and re-run to produce the .AppImage."
fi

cat <<'EOF'

NOTE: First run on a clean system still needs the udev rule:
  sudo cp packaging/70-emeet-pixy.rules /etc/udev/rules.d/
  sudo udevadm control --reload-rules && sudo udevadm trigger
Then replug the camera. The app's System panel can also install it.
EOF
