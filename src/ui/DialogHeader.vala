namespace Vector.Ui {

    // unified header layout for subdialogs: Cancel left, action right, no window close buttons
    public class DialogHeader : GLib.Object {

        // on_cancel null = omit Cancel button (e.g. Done button for auto-saving dialogs)
        public static Adw.HeaderBar create (string title, string subtitle, Gtk.Button action,
                                            owned Callback? on_cancel) {
            var header = new Adw.HeaderBar ();
            header.title_widget = new Adw.WindowTitle (title, subtitle);
            header.show_start_title_buttons = false;
            header.show_end_title_buttons = false;
            header.show_back_button = false;
            if (on_cancel != null) {
                var cancel = new Gtk.Button.with_label ("Cancel");
                cancel.clicked.connect (() => { on_cancel (); });
                header.pack_start (cancel);
            }
            action.add_css_class ("suggested-action");
            header.pack_end (action);
            return header;
        }
    }
}
