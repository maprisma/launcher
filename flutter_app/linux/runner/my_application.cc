#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // "maprisma-launcher/window": tells the app its window is shown again (popup mode
  // places it then).
  FlMethodChannel* window_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void notify_shown(MyApplication* self) {
  if (self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, "shown", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

// The window's focus, for the popup mode (a click elsewhere hides it).
static gboolean focus_changed_cb(GtkWidget* widget, GdkEventFocus* event, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, event->in ? "focus" : "blur", nullptr,
                                    nullptr, nullptr, nullptr);
  }
  return FALSE;
}

// "titlebar": GTK draws the title bar, so it takes the app's light or dark.
static void window_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
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
  } else if (g_strcmp0(fl_method_call_get_name(call), "hide") == 0) {
    // "hide": the window steps aside (after a start, on Esc); the process
    // stays, so the next --toggle shows it at once.
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
    gtk_widget_hide(GTK_WIDGET(window));
    return;
  }
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_present(window);
  notify_shown(self);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
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
    if (g_strcmp0(*arg, "--toggle") == 0) {
      toggle = TRUE;
    } else {
      g_ptr_array_add(kept, g_strdup(*arg));
    }
  }
  g_ptr_array_add(kept, nullptr);
  self->dart_entrypoint_arguments =
      reinterpret_cast<char**>(g_ptr_array_free(kept, FALSE));

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
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
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

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}
