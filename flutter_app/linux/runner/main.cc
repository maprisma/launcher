#include <string.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // --dock: the dock, a process of its own (see my_application.cc).
  gboolean dock = FALSE;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--dock") == 0) dock = TRUE;
  }
  g_autoptr(MyApplication) app = my_application_new(dock);
  int status = g_application_run(G_APPLICATION(app), argc, argv);
  return status != 0 ? status : my_application_exit_code(app);
}
