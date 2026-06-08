#include <cstdlib>

#include "my_application.h"

int main(int argc, char** argv) {
  // Flutter's Linux GTK backend uploads decoded images to GL textures on a
  // cross-context IO thread (SkImages::CrossContextTextureFromPixmap). On this
  // box's radeonsi/Mesa stack (AMD RX 6700 XT, navi22) that path SIGSEGVs inside
  // libgallium during the texture upload — reliably reproduced whenever the live
  // MJPEG preview pushes frames. Forcing the llvmpipe software rasterizer avoids
  // the broken driver path entirely; the UI is light and CPU raster keeps up.
  //
  // Opt back into hardware GL on a stable GPU/driver with PIXY_GPU=1. Respect an
  // existing LIBGL_ALWAYS_SOFTWARE if the user already set one.
  if (getenv("PIXY_GPU") == nullptr && getenv("LIBGL_ALWAYS_SOFTWARE") == nullptr) {
    setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
  }
  // Silence the harmless `atk_socket_embed: assertion 'plug_id != NULL'` AT-SPI
  // bridge noise (no a11y consumer on the bus). Cosmetic only.
  if (getenv("NO_AT_BRIDGE") == nullptr) {
    setenv("NO_AT_BRIDGE", "1", 1);
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
