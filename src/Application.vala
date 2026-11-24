using Vector.Services;
namespace Vector {

    public class Application : Adw.Application {

        public Application () {
            Object (
                application_id: "io.github.dp0sk.Vector",
                // don't hand over to running instance if VECTOR_UNIT_SUFFIX is set (for testing)
                flags: Paths.unit_suffix () != "" ? GLib.ApplicationFlags.NON_UNIQUE
                                                   : GLib.ApplicationFlags.DEFAULT_FLAGS
            );
        }

        protected override void startup () {
            base.startup ();

            Gtk.Window.set_default_icon_name ("io.github.dp0sk.Vector");

            var about_action = new GLib.SimpleAction ("about", null);
            about_action.activate.connect (() => {
                if (main_window != null) main_window.show_about ();
            });
            this.add_action (about_action);

            var exit_action = new GLib.SimpleAction ("full-exit", null);
            exit_action.activate.connect (() => {
                if (main_window != null) main_window.full_exit ();
                else this.quit ();
            });
            this.add_action (exit_action);
        }

        private MainWindow? main_window = null;

        protected override void activate () {
            if (main_window == null) {
                main_window = new MainWindow (this);
            }

            main_window.present ();
        }

        protected override void window_removed (Gtk.Window window) {
            base.window_removed (window);
            if (window == main_window) main_window = null;
        }

        public static int main (string[] args) {
            GLib.Environment.set_prgname ("io.github.dp0sk.Vector");
            GLib.Environment.set_application_name ("Vector");
            return new Application ().run (args);
        }
    }
}
