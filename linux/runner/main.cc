#include <cstdlib>

#include "my_application.h"

int main(int argc, char** argv) {
  // Default: hardware GL on native Wayland — smooth, no flicker.
  //
  // Trade-off worth knowing: Flutter's Linux GTK backend uploads decoded images
  // to GL textures on a cross-context IO thread (SkImages::CrossContextTextureFromPixmap),
  // and on some radeonsi/Mesa stacks (AMD RX 6700 XT, navi22) that path SIGSEGVs
  // inside libgallium when the live MJPEG preview pushes frames. If that bites,
  // PIXY_SOFTWARE=1 forces the llvmpipe software rasterizer (crash-safe) plus the
  // XWayland backend (software GL flickers under native Wayland but presents
  // cleanly through XWayland). An explicit LIBGL_ALWAYS_SOFTWARE / GDK_BACKEND
  // still wins.
  if (getenv("PIXY_SOFTWARE") != nullptr) {
    if (getenv("LIBGL_ALWAYS_SOFTWARE") == nullptr) {
      setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    }
    if (getenv("GDK_BACKEND") == nullptr) {
      setenv("GDK_BACKEND", "x11", 1);
    }
  }
  // Silence the harmless `atk_socket_embed: assertion 'plug_id != NULL'` AT-SPI
  // bridge noise. Counter-intuitively NO_AT_BRIDGE=1 *triggers* that assertion
  // (GTK asks the absent bridge for a plug id and gets NULL), so clear it and
  // disable GTK accessibility the modern way instead. Cosmetic only.
  unsetenv("NO_AT_BRIDGE");
  if (getenv("GTK_A11Y") == nullptr) {
    setenv("GTK_A11Y", "none", 1);
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
