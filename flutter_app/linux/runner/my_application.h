#ifndef FLUTTER_MY_APPLICATION_H_
#define FLUTTER_MY_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(MyApplication,
                     my_application,
                     MY,
                     APPLICATION,
                     GtkApplication)

/**
 * my_application_new:
 * @dock: the dock (`--dock`): its own application id and a layer-shell
 * window instead of the app's window.
 *
 * Creates a new Flutter-based application.
 *
 * Returns: a new #MyApplication.
 */
MyApplication* my_application_new(gboolean dock);

/**
 * my_application_exit_code: non-zero when the dock refused to start.
 */
int my_application_exit_code(MyApplication* self);

#endif  // FLUTTER_MY_APPLICATION_H_
