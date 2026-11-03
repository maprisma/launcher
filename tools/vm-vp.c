// Virtual pointer for the edge VM only: reads lines from stdin:
//   size W H | move X Y | glide X Y MS | down [B] | up [B] | click [B] | sleep MS
// B: left (default), right, middle. Logical coordinates over the W×H extent.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "vp-protocol.h"

static struct zwlr_virtual_pointer_manager_v1* manager;
static struct wl_seat* seat;

static void global(void* d, struct wl_registry* r, uint32_t name, const char* iface, uint32_t v) {
  if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0)
    manager = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
  else if (strcmp(iface, wl_seat_interface.name) == 0)
    seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
}
static void global_remove(void* d, struct wl_registry* r, uint32_t name) {}
static const struct wl_registry_listener listener = {global, global_remove};

static uint32_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int button(const char* b) {
  if (b && strcmp(b, "right") == 0) return 0x111;
  if (b && strcmp(b, "middle") == 0) return 0x112;
  return 0x110;
}

int main(void) {
  struct wl_display* display = wl_display_connect(NULL);
  if (!display) { fprintf(stderr, "vp: no display\n"); return 1; }
  struct wl_registry* registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &listener, NULL);
  wl_display_roundtrip(display);
  if (!manager) { fprintf(stderr, "vp: no virtual pointer manager\n"); return 1; }
  struct zwlr_virtual_pointer_v1* p = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
  unsigned w = 1920, h = 1080, x = 0, y = 0;
  char line[256];
  while (fgets(line, sizeof line, stdin)) {
    char cmd[32] = "", a[32] = "";
    unsigned n1 = 0, n2 = 0, n3 = 0;
    sscanf(line, "%31s", cmd);
    if (strcmp(cmd, "size") == 0) {
      sscanf(line, "%*s %u %u", &w, &h);
    } else if (strcmp(cmd, "move") == 0) {
      sscanf(line, "%*s %u %u", &x, &y);
      zwlr_virtual_pointer_v1_motion_absolute(p, now_ms(), x, y, w, h);
      zwlr_virtual_pointer_v1_frame(p);
    } else if (strcmp(cmd, "glide") == 0) {
      sscanf(line, "%*s %u %u %u", &n1, &n2, &n3);
      int steps = n3 / 16 + 1;
      for (int i = 1; i <= steps; i++) {
        unsigned cx = x + ((int)n1 - (int)x) * i / steps, cy = y + ((int)n2 - (int)y) * i / steps;
        zwlr_virtual_pointer_v1_motion_absolute(p, now_ms(), cx, cy, w, h);
        zwlr_virtual_pointer_v1_frame(p);
        wl_display_flush(display);
        usleep(16000);
      }
      x = n1, y = n2;
    } else if (strcmp(cmd, "down") == 0 || strcmp(cmd, "up") == 0 || strcmp(cmd, "click") == 0) {
      sscanf(line, "%*s %31s", a);
      int b = button(a[0] ? a : NULL);
      if (strcmp(cmd, "up") != 0) {
        zwlr_virtual_pointer_v1_button(p, now_ms(), b, WL_POINTER_BUTTON_STATE_PRESSED);
        zwlr_virtual_pointer_v1_frame(p);
      }
      if (strcmp(cmd, "click") == 0) { wl_display_flush(display); usleep(60000); }
      if (strcmp(cmd, "down") != 0) {
        zwlr_virtual_pointer_v1_button(p, now_ms(), b, WL_POINTER_BUTTON_STATE_RELEASED);
        zwlr_virtual_pointer_v1_frame(p);
      }
    } else if (strcmp(cmd, "sleep") == 0) {
      sscanf(line, "%*s %u", &n1);
      wl_display_flush(display);
      usleep(n1 * 1000);
    }
    wl_display_roundtrip(display);
  }
  zwlr_virtual_pointer_v1_destroy(p);
  wl_display_roundtrip(display);
  return 0;
}
