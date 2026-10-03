#include <stdlib.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // NVIDIA drivers queue up to three frames by default; in a composited
  // (windowed) session that adds visible input lag. One queued frame keeps
  // the game responsive. Ignored by other drivers; an existing value wins.
  setenv("__GL_MaxFramesAllowed", "1", 0);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
