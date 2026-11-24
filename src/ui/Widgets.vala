using Vector.Models;

namespace Vector.Ui {

    public delegate void Callback ();

    public class Widgets : GLib.Object {

        // two-way bind widget property directly to AppSettings without needing updating_ui guards.
        // programmatic updates hit settings.notify[canonical] so we avoid recursive signal storms.
        public static void bind_switch (GLib.Object row, AppSettings s, string prop) {
            bind_setting (row, "active", s, prop);
        }

        public static void bind_setting (GLib.Object row, string row_prop, AppSettings s, string prop) {
            string canonical = prop.replace ("_", "-");
            s.bind_property (canonical, row, row_prop,
                GLib.BindingFlags.BIDIRECTIONAL | GLib.BindingFlags.SYNC_CREATE);
            s.notify[canonical].connect (() => s.save ());
        }

        public static Gtk.Button icon_label_button (string icon, string label) {
            var content = new Adw.ButtonContent ();
            content.icon_name = icon;
            content.label = label;
            var btn = new Gtk.Button ();
            btn.child = content;
            btn.add_css_class ("flat");
            btn.valign = Gtk.Align.CENTER;
            return btn;
        }

        public static Gtk.Button icon_button (string icon, string tooltip) {
            var btn = new Gtk.Button.from_icon_name (icon);
            btn.tooltip_text = tooltip;
            btn.add_css_class ("flat");
            btn.valign = Gtk.Align.CENTER;
            return btn;
        }

        public static void confirm_delete (Gtk.Widget parent, string heading, string body,
                                           owned Callback on_delete) {
            var dialog = new Adw.AlertDialog (heading, body);
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("delete", "Delete");
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            dialog.response.connect ((d, response) => {
                if (response == "delete") on_delete ();
            });
            dialog.present (parent);
        }

        // GTK 4.18 brain damage: gtk_string_list_new expects a NULL-terminated char**,
        // but Vala's string[] doesn't emit a sentinel NULL at the end. Passing it directly
        // caused GTK to read adjacent garbage memory. Append items one by one instead.
        public static Gtk.StringList string_list (string[] items) {
            var sl = new Gtk.StringList (null);
            foreach (var s in items) sl.append (s);
            return sl;
        }

        // valac versions can't agree on whether gtk_drag_icon_get_for_drag is a constructor or a static method.
        // bind the C symbol directly so builds don't randomly fail across distros.
        [CCode (cname = "gtk_drag_icon_get_for_drag")]
        public static extern unowned Gtk.Widget drag_icon_for (Gdk.Drag drag);
    }
}
