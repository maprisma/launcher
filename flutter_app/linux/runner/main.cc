#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "my_application.h"

// Kept readable in the runner binary so MCP scanners recognise `maprisma-launcher mcp`.
static const char kMcpHint[] =
    "Usage: maprisma-launcher mcp [--config-dir PATH]\n"
    "protocolVersion notifications/initialized tools/list";

static int exec_mcp(int argc, char** argv) {
  (void)kMcpHint;
  char self[PATH_MAX];
  ssize_t len = readlink("/proc/self/exe", self, sizeof(self) - 1);
  if (len <= 0 || len >= static_cast<ssize_t>(sizeof(self))) {
    fprintf(stderr, "maprisma-launcher mcp: could not locate executable path\n");
    return 127;
  }
  self[len] = '\0';
  char* slash = strrchr(self, '/');
  if (slash == nullptr) {
    fprintf(stderr, "maprisma-launcher mcp: unexpected executable path\n");
    return 127;
  }
  *slash = '\0';

  char helper[PATH_MAX];
  int n = snprintf(helper, sizeof(helper), "%s/lib/maprisma-launcher-core", self);
  if (n <= 0 || n >= static_cast<int>(sizeof(helper))) {
    fprintf(stderr, "maprisma-launcher mcp: helper path too long\n");
    return 127;
  }

  char** child_argv = static_cast<char**>(calloc(static_cast<size_t>(argc) + 1, sizeof(char*)));
  if (child_argv == nullptr) return 127;
  child_argv[0] = helper;
  child_argv[1] = const_cast<char*>("mcp");
  for (int i = 2; i < argc; i++) {
    child_argv[i] = argv[i];
  }
  child_argv[argc] = nullptr;

  execv(helper, child_argv);
  perror("maprisma-launcher mcp");
  free(child_argv);
  return 127;
}

int main(int argc, char** argv) {
  // `maprisma-launcher mcp` / `--mcp`: pure stdio MCP server without GTK/display.
  if (argc >= 2 && (strcmp(argv[1], "mcp") == 0 || strcmp(argv[1], "--mcp") == 0)) {
    return exec_mcp(argc, argv);
  }
  // --dock: the dock, a process of its own (see my_application.cc).
  gboolean dock = FALSE;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--dock") == 0) dock = TRUE;
  }
  g_autoptr(MyApplication) app = my_application_new(dock);
  int status = g_application_run(G_APPLICATION(app), argc, argv);
  return status != 0 ? status : my_application_exit_code(app);
}
