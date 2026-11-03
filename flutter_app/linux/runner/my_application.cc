#include "my_application.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#include <wayland-client-protocol.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // "maprisma-launcher/window": tells the app its window is shown again (popup mode
  // places it then).
  FlMethodChannel* window_channel;
  gboolean grab_enabled;
  gboolean window_focused;
#ifdef GDK_WINDOWING_WAYLAND
  struct wl_proxy* grab_manager;
  struct wl_proxy* active_grab;
#endif
  // The dock (--dock): a layer-shell window, "maprisma-launcher/dock".
  gboolean dock;
  GtkWindow* dock_window;
  FlMethodChannel* dock_channel;
  int exit_code;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// --- Hyprland focus grab (hyprland_focus_grab_v1) -----------------------------
//
// On Hyprland, follow_mouse = 1 shifts focus whenever the pointer crosses the
// popup's edge onto a tiled window behind it. Holding a focus grab on the
// popup's wl_surface keeps focus while hovering outside and clears the grab
// (firing "cleared") only when the user actually clicks outside.

#ifdef GDK_WINDOWING_WAYLAND
extern const struct wl_interface hyprland_focus_grab_v1_interface;

static const struct wl_interface* focus_grab_types[] = {
    &hyprland_focus_grab_v1_interface,
    nullptr,
    &wl_surface_interface,
    &wl_surface_interface,
};

static const struct wl_message focus_grab_manager_requests[] = {
    {"create_grab", "n", &focus_grab_types[0]},
    {"destroy", "", &focus_grab_types[1]},
};

const struct wl_interface hyprland_focus_grab_manager_v1_interface = {
    "hyprland_focus_grab_manager_v1", 1,
    2, focus_grab_manager_requests,
    0, nullptr,
};

static const struct wl_message focus_grab_requests[] = {
    {"add_surface", "o", &focus_grab_types[2]},
    {"remove_surface", "o", &focus_grab_types[3]},
    {"commit", "", &focus_grab_types[1]},
    {"destroy", "", &focus_grab_types[1]},
};

static const struct wl_message focus_grab_events[] = {
    {"cleared", "", &focus_grab_types[1]},
};

const struct wl_interface hyprland_focus_grab_v1_interface = {
    "hyprland_focus_grab_v1", 1,
    4, focus_grab_requests,
    1, focus_grab_events,
};

static void registry_global_cb(void* data, struct wl_registry* registry,
                               uint32_t name, const char* interface,
                               uint32_t version) {
  MyApplication* self = MY_APPLICATION(data);
  if (g_strcmp0(interface, "hyprland_focus_grab_manager_v1") == 0 &&
      self->grab_manager == nullptr) {
    self->grab_manager = static_cast<struct wl_proxy*>(wl_registry_bind(
        registry, name, &hyprland_focus_grab_manager_v1_interface, 1));
  }
}

static void registry_remove_cb(void* data, struct wl_registry* registry,
                               uint32_t name) {}

static const struct wl_registry_listener registry_listener = {
    registry_global_cb,
    registry_remove_cb,
};

static void ensure_grab_manager(MyApplication* self) {
  if (self->grab_manager != nullptr) return;
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) return;
  struct wl_display* display = gdk_wayland_display_get_wl_display(gdk_display);
  if (display == nullptr) return;
  // A private queue: the round trip then dispatches only the registry's
  // events, never GDK's own (which must not run inside a GTK handler).
  struct wl_event_queue* queue = wl_display_create_queue(display);
  if (queue == nullptr) return;
  struct wl_display* wrapped =
      static_cast<struct wl_display*>(wl_proxy_create_wrapper(display));
  if (wrapped == nullptr) {
    wl_event_queue_destroy(queue);
    return;
  }
  wl_proxy_set_queue(reinterpret_cast<struct wl_proxy*>(wrapped), queue);
  struct wl_registry* registry = wl_display_get_registry(wrapped);
  wl_proxy_wrapper_destroy(wrapped);
  wl_registry_add_listener(registry, &registry_listener, self);
  wl_display_roundtrip_queue(display, queue);
  wl_registry_destroy(registry);
  // The manager (and the grabs made from it) back on the default queue, so
  // "cleared" arrives through GTK's own loop.
  if (self->grab_manager != nullptr) wl_proxy_set_queue(self->grab_manager, nullptr);
  wl_event_queue_destroy(queue);
}

static void release_focus_grab(MyApplication* self) {
  if (self->active_grab == nullptr) return;
  struct wl_proxy* grab = self->active_grab;
  self->active_grab = nullptr;
  wl_proxy_marshal_flags(grab, 3 /* destroy */, nullptr,
                         wl_proxy_get_version(grab), WL_MARSHAL_FLAG_DESTROY);
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display != nullptr && GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
    wl_display_flush(gdk_wayland_display_get_wl_display(gdk_display));
  }
}

static void grab_cleared_cb(void* data, struct wl_proxy* proxy) {
  MyApplication* self = MY_APPLICATION(data);
  if (self->active_grab == proxy) {
    self->active_grab = nullptr;
    wl_proxy_marshal_flags(proxy, 3 /* destroy */, nullptr,
                           wl_proxy_get_version(proxy),
                           WL_MARSHAL_FLAG_DESTROY);
  }
  self->window_focused = FALSE;
  if (self->grab_enabled && self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, "outside", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

static void (* const grab_listener[])(void) = {
    reinterpret_cast<void (*)(void)>(grab_cleared_cb),
};

static void sync_focus_grab(MyApplication* self) {
  GtkWindow* window =
      gtk_application_get_active_window(GTK_APPLICATION(self));
  if (!self->grab_enabled || !self->window_focused || window == nullptr ||
      !gtk_widget_get_visible(GTK_WIDGET(window))) {
    release_focus_grab(self);
    return;
  }
  if (self->active_grab != nullptr) return;
  ensure_grab_manager(self);
  if (self->grab_manager == nullptr) return;
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window == nullptr || !GDK_IS_WAYLAND_WINDOW(gdk_window)) return;
  struct wl_surface* surface = gdk_wayland_window_get_wl_surface(gdk_window);
  if (surface == nullptr) return;
  struct wl_proxy* grab = wl_proxy_marshal_flags(
      self->grab_manager, 0 /* create_grab */,
      &hyprland_focus_grab_v1_interface,
      wl_proxy_get_version(self->grab_manager), 0, nullptr);
  if (grab == nullptr) return;
  self->active_grab = grab;
  wl_proxy_add_listener(grab, const_cast<void (**)(void)>(grab_listener), self);
  wl_proxy_marshal_flags(grab, 0 /* add_surface */, nullptr,
                         wl_proxy_get_version(grab), 0, surface);
  wl_proxy_marshal_flags(grab, 2 /* commit */, nullptr,
                         wl_proxy_get_version(grab), 0);
  wl_display_flush(
      gdk_wayland_display_get_wl_display(gdk_display_get_default()));
}
#else
static void release_focus_grab(MyApplication* self) {}
static void sync_focus_grab(MyApplication* self) {}
#endif

static void notify_shown(MyApplication* self) {
  if (self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, "shown", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

// The window's focus, for the popup mode (a click elsewhere hides it).
static gboolean focus_changed_cb(GtkWidget* widget, GdkEventFocus* event, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->window_focused = event->in;
  if (event->in) {
    sync_focus_grab(self);
  } else {
    release_focus_grab(self);
  }
  if (self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, event->in ? "focus" : "blur", nullptr,
                                    nullptr, nullptr, nullptr);
  }
  return FALSE;
}

// "titlebar": GTK draws the title bar, so it takes the app's light or dark.
static void window_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "titlebar") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      g_object_set(gtk_settings_get_default(),
                   "gtk-application-prefer-dark-theme", fl_value_get_bool(args),
                   nullptr);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(fl_method_call_get_name(call), "decorated") == 0) {
    // "decorated": false on Omarchy's popup (Hyprland draws the border; the
    // app's header is enough).
    FlValue* args = fl_method_call_get_args(call);
    GtkWindow* window = gtk_application_get_active_window(
        GTK_APPLICATION(g_application_get_default()));
    if (window != nullptr && args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      gtk_window_set_decorated(window, fl_value_get_bool(args));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(fl_method_call_get_name(call), "grab") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      self->grab_enabled = fl_value_get_bool(args);
      sync_focus_grab(self);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(fl_method_call_get_name(call), "hide") == 0) {
    // "hide": the window steps aside (after a start, on Esc); the process
    // stays, so the next --toggle shows it at once.
    release_focus_grab(self);
    self->window_focused = FALSE;
    GtkWindow* window = gtk_application_get_active_window(
        GTK_APPLICATION(g_application_get_default()));
    if (window != nullptr) gtk_widget_hide(GTK_WIDGET(window));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  notify_shown(self);
}

// The "toggle" action (appmanager --toggle, the bar icon): the window hides
// when it is shown and focused, else it is shown and focused.
static void toggle_activated(GSimpleAction* action, GVariant* parameter,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window =
      gtk_application_get_active_window(GTK_APPLICATION(self));
  if (window == nullptr) {
    g_application_activate(G_APPLICATION(self));
    return;
  }
  if (gtk_widget_get_visible(GTK_WIDGET(window)) &&
      gtk_window_is_active(window)) {
    release_focus_grab(self);
    self->window_focused = FALSE;
    gtk_widget_hide(GTK_WIDGET(window));
    return;
  }
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_present(window);
  notify_shown(self);
}


// --- the dock -----------------------------------------------------------------
//
// gtk-layer-shell (GTK3, package gtk-layer-shell) is optional: it is loaded
// with dlopen when the dock starts, and the dock refuses to start without it.
// gtk_layer_init_for_window must run before the window is realized.

static const char* kLayerShellLibrary = "libgtk-layer-shell.so.0";
enum { kEdgeLeft = 0, kEdgeRight = 1, kEdgeTop = 2, kEdgeBottom = 3 };
enum { kLayerTop = 2 };
enum { kKeyboardNone = 0 };

static struct {
  gboolean (*is_supported)();
  void (*init_for_window)(GtkWindow*);
  void (*set_namespace)(GtkWindow*, const char*);
  void (*set_layer)(GtkWindow*, int);
  void (*set_anchor)(GtkWindow*, int, gboolean);
  void (*set_margin)(GtkWindow*, int, int);
  void (*set_exclusive_zone)(GtkWindow*, int);
  void (*set_keyboard_mode)(GtkWindow*, int);
  void (*set_keyboard_interactivity)(GtkWindow*, gboolean);
} layer;

// Loads the library and its functions; FALSE (with a message) when it is missing.
static gboolean load_layer_shell() {
  void* lib = dlopen(kLayerShellLibrary, RTLD_NOW | RTLD_LOCAL);
  if (lib == nullptr) {
    g_printerr("maprisma-launcher --dock: the dock needs gtk-layer-shell (%s), which is not installed: %s\n",
               kLayerShellLibrary, dlerror());
    return FALSE;
  }
#define LAYER_FN(field, name) *reinterpret_cast<void**>(&layer.field) = dlsym(lib, name)
  LAYER_FN(is_supported, "gtk_layer_is_supported");
  LAYER_FN(init_for_window, "gtk_layer_init_for_window");
  LAYER_FN(set_namespace, "gtk_layer_set_namespace");
  LAYER_FN(set_layer, "gtk_layer_set_layer");
  LAYER_FN(set_anchor, "gtk_layer_set_anchor");
  LAYER_FN(set_margin, "gtk_layer_set_margin");
  LAYER_FN(set_exclusive_zone, "gtk_layer_set_exclusive_zone");
  LAYER_FN(set_keyboard_mode, "gtk_layer_set_keyboard_mode");
  LAYER_FN(set_keyboard_interactivity, "gtk_layer_set_keyboard_interactivity");
#undef LAYER_FN
  if (layer.init_for_window == nullptr || layer.set_layer == nullptr || layer.set_anchor == nullptr ||
      layer.set_margin == nullptr || layer.set_exclusive_zone == nullptr || layer.set_namespace == nullptr) {
    g_printerr("maprisma-launcher --dock: %s is too old (gtk_layer_* functions missing)\n", kLayerShellLibrary);
    return FALSE;
  }
  return TRUE;
}

static int edge_number(const gchar* edge) {
  if (g_strcmp0(edge, "top") == 0) return kEdgeTop;
  if (g_strcmp0(edge, "left") == 0) return kEdgeLeft;
  if (g_strcmp0(edge, "right") == 0) return kEdgeRight;
  return kEdgeBottom;
}

static int64_t map_int(FlValue* map, const char* key, int64_t fallback) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT ? fl_value_get_int(value) : fallback;
}

// "layout": {edge, thickness, exclusive}: anchored to the edge and along its
// whole length; Flutter draws the band where it belongs and keeps the rest
// of the surface out of the input region ("input").
static void dock_layout(GtkWindow* window, FlValue* args) {
  FlValue* edge_value = fl_value_lookup_string(args, "edge");
  const gchar* edge =
      edge_value != nullptr && fl_value_get_type(edge_value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(edge_value) : "bottom";
  int at = edge_number(edge);
  int thickness = (int)CLAMP(map_int(args, "thickness", 48), 1, 2000);
  int exclusive = (int)CLAMP(map_int(args, "exclusive", 0), 0, 1000);
  gboolean vertical = at == kEdgeLeft || at == kEdgeRight;
  for (int e = 0; e < 4; e++) {
    gboolean along = vertical ? (e == kEdgeTop || e == kEdgeBottom) : (e == kEdgeLeft || e == kEdgeRight);
    layer.set_anchor(window, e, e == at || along);
    layer.set_margin(window, e, 0);
  }
  layer.set_exclusive_zone(window, exclusive);
  if (vertical) {
    gtk_widget_set_size_request(GTK_WIDGET(window), thickness, -1);
  } else {
    gtk_widget_set_size_request(GTK_WIDGET(window), -1, thickness);
  }
  gtk_window_resize(window, 1, 1);
}

// "input": [[x, y, w, h], …] in logical pixels; null: the whole surface.
static void dock_input(GtkWindow* window, FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_LIST) {
    gtk_widget_input_shape_combine_region(GTK_WIDGET(window), nullptr);
    return;
  }
  cairo_region_t* region = cairo_region_create();
  for (size_t i = 0; i < fl_value_get_length(args) && i < 64; i++) {
    FlValue* rect = fl_value_get_list_value(args, i);
    if (fl_value_get_type(rect) != FL_VALUE_TYPE_LIST || fl_value_get_length(rect) != 4) continue;
    int v[4];
    gboolean ok = TRUE;
    for (int k = 0; k < 4; k++) {
      FlValue* n = fl_value_get_list_value(rect, k);
      if (fl_value_get_type(n) == FL_VALUE_TYPE_INT) {
        v[k] = (int)CLAMP(fl_value_get_int(n), -100000, 100000);
      } else if (fl_value_get_type(n) == FL_VALUE_TYPE_FLOAT) {
        v[k] = (int)CLAMP(fl_value_get_float(n), -100000, 100000);
      } else {
        ok = FALSE;
      }
    }
    if (!ok || v[2] <= 0 || v[3] <= 0) continue;
    cairo_rectangle_int_t r = {v[0], v[1], v[2], v[3]};
    cairo_region_union_rectangle(region, &r);
  }
  gtk_widget_input_shape_combine_region(GTK_WIDGET(window), region);
  cairo_region_destroy(region);
}

static void dock_call_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* name = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(name, "layout") == 0 && self->dock_window != nullptr && args != nullptr &&
      fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    dock_layout(self->dock_window, args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "input") == 0 && self->dock_window != nullptr) {
    dock_input(self->dock_window, args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "quit") == 0) {
    // Switched off (or refused): the process ends.
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_INT) self->exit_code = (int)fl_value_get_int(args);
    g_application_quit(G_APPLICATION(self));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

static void dock_first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// The dock's window: a transparent layer surface on the top layer that never
// takes the keyboard. Started again: the running dock re-reads its settings.
static void dock_activate(MyApplication* self) {
  if (self->dock_window != nullptr) {
    if (self->dock_channel != nullptr) {
      fl_method_channel_invoke_method(self->dock_channel, "reload", nullptr, nullptr, nullptr, nullptr);
    }
    return;
  }
  if (layer.is_supported != nullptr && !layer.is_supported()) {
    g_printerr("maprisma-launcher --dock: this session has no layer shell (Wayland with wlr-layer-shell is needed)\n");
    self->exit_code = 4;
    return;
  }
  GtkWindow* window = GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(self)));
  gtk_window_set_title(window, "Maprisma Launcher Dock");
  gtk_window_set_decorated(window, FALSE);
  GdkVisual* visual = gdk_screen_get_rgba_visual(gtk_widget_get_screen(GTK_WIDGET(window)));
  if (visual != nullptr) gtk_widget_set_visual(GTK_WIDGET(window), visual);
  gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  layer.init_for_window(window);
  layer.set_namespace(window, "maprisma-launcher-dock");
  layer.set_layer(window, kLayerTop);
  if (layer.set_keyboard_mode != nullptr) {
    layer.set_keyboard_mode(window, kKeyboardNone);
  } else if (layer.set_keyboard_interactivity != nullptr) {
    layer.set_keyboard_interactivity(window, FALSE);
  }
  g_autoptr(FlValue) start = fl_value_new_map();
  fl_value_set_string_take(start, "edge", fl_value_new_string("bottom"));
  fl_value_set_string_take(start, "thickness", fl_value_new_int(2));
  fl_value_set_string_take(start, "exclusive", fl_value_new_int(0));
  dock_layout(window, start);
  self->dock_window = window;

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);
  FlView* view = fl_view_new(project);
  GdkRGBA clear = {0, 0, 0, 0};
  fl_view_set_background_color(view, &clear);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(dock_first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->dock_channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),
                                             "maprisma-launcher/dock", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->dock_channel, dock_call_cb, self, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->dock) {
    dock_activate(self);
    return;
  }
  GtkWindow* existing = gtk_application_get_active_window(GTK_APPLICATION(application));
  if (existing != nullptr) {
    gtk_widget_show(GTK_WIDGET(existing));
    gtk_window_present(existing);
    notify_shown(self);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Maprisma Launcher");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Maprisma Launcher");
  }

  gtk_window_set_default_size(window, 920, 640);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "maprisma-launcher/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel,
                                            window_call_cb, self, nullptr);

  g_signal_connect(window, "focus-in-event", G_CALLBACK(focus_changed_cb), self);
  g_signal_connect(window, "focus-out-event", G_CALLBACK(focus_changed_cb), self);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name; --toggle is the
  // runner's own (the bar icon), not the app's.
  gboolean toggle = FALSE;
  GPtrArray* kept = g_ptr_array_new();
  for (gchar** arg = *arguments + 1; *arg != nullptr; arg++) {
    if (g_strcmp0(*arg, "--toggle") == 0 && !self->dock) {
      toggle = TRUE;
    } else {
      g_ptr_array_add(kept, g_strdup(*arg));
    }
  }
  g_ptr_array_add(kept, nullptr);
  self->dart_entrypoint_arguments =
      reinterpret_cast<char**>(g_ptr_array_free(kept, FALSE));

  // The dock (--dock stays among the Dart arguments: main.dart starts the
  // dock then). Without gtk-layer-shell it refuses before anything shows.
  if (self->dock && !load_layer_shell()) {
    *exit_status = 3;
    return TRUE;
  }

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // Another instance runs: it shows or hides its window. Else this one
  // starts as usual (shown).
  if (toggle && g_application_get_is_remote(application)) {
    g_action_group_activate_action(G_ACTION_GROUP(application), "toggle",
                                   nullptr);
    // Sent before this process ends.
    GDBusConnection* bus = g_application_get_dbus_connection(application);
    if (bus != nullptr) g_dbus_connection_flush_sync(bus, nullptr, nullptr);
    *exit_status = 0;
    return TRUE;
  }
  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  g_autoptr(GSimpleAction) toggle = g_simple_action_new("toggle", nullptr);
  g_signal_connect(toggle, "activate", G_CALLBACK(toggle_activated),
                   application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(toggle));
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  release_focus_grab(self);
#ifdef GDK_WINDOWING_WAYLAND
  if (self->grab_manager != nullptr) {
    wl_proxy_marshal_flags(self->grab_manager, 1 /* destroy */, nullptr,
                           wl_proxy_get_version(self->grab_manager),
                           WL_MARSHAL_FLAG_DESTROY);
    self->grab_manager = nullptr;
  }
#endif
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  g_clear_object(&self->dock_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

int my_application_exit_code(MyApplication* self) { return self->exit_code; }

MyApplication* my_application_new(gboolean dock) {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  // The dock is a single instance of its own, apart from the app's window.
  const gchar* id = dock ? APPLICATION_ID ".Dock" : APPLICATION_ID;
  g_set_prgname(id);

  MyApplication* self = MY_APPLICATION(g_object_new(my_application_get_type(),
                                                    "application-id", id, "flags",
                                                    G_APPLICATION_DEFAULT_FLAGS, nullptr));
  self->dock = dock;
  return self;
}
