using Vector.Models;
using Vector.Subs;
using Vector.Services;
namespace Vector.Ui {

    // modal for tweaking sub group: name, auto-update timer, headers and url list
    public class GroupEditDialog : Adw.Dialog {

        public signal void saved ();

        private Store store;
        private SubGroup group;
        private bool is_new;

        private Adw.EntryRow name_row;
        private Adw.SwitchRow auto_update_row;
        private Adw.SpinRow interval_row;
        private PresetEntryRow user_agent_row;
        private Adw.PreferencesGroup headers_group;
        private Adw.PreferencesGroup urls_group;

        private class HeaderRow : GLib.Object {
            public Adw.ActionRow row;
            public Gtk.Entry name;
            public Gtk.Entry value;
        }
        private GLib.GenericArray<HeaderRow> header_rows = new GLib.GenericArray<HeaderRow> ();
        private GLib.GenericArray<Adw.EntryRow> url_rows = new GLib.GenericArray<Adw.EntryRow> ();

        private const int MIN_INTERVAL = 5; // minutes

        public GroupEditDialog (Store store, SubGroup? existing) {
            this.store = store;
            this.is_new = existing == null;
            this.group = existing ?? new SubGroup ("");

            title = is_new ? "New Group" : "Edit Group";
            content_width = 560;
            content_height = 680;

            var page = new Adw.PreferencesPage ();
            page.add (build_general_group ());
            page.add (build_headers_group ());
            page.add (build_urls_group ());

            var save_btn = new Gtk.Button.with_label ("Save");
            save_btn.clicked.connect (on_save);

            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (DialogHeader.create (title, "", save_btn, () => { close (); }));
            toolbar.content = page;
            child = toolbar;
        }

        private Adw.PreferencesGroup build_general_group () {
            name_row = new Adw.EntryRow ();
            name_row.title = "Name";
            name_row.text = group.name;
            name_row.changed.connect (() => { name_row.remove_css_class ("error"); });

            auto_update_row = new Adw.SwitchRow ();
            auto_update_row.title = "Auto-update";
            auto_update_row.active = group.enable_update;

            interval_row = new Adw.SpinRow.with_range (MIN_INTERVAL, 10080, 5);
            interval_row.title = "Every (min)";
            interval_row.value = int.max (group.update_interval, MIN_INTERVAL);

            var section = new Adw.PreferencesGroup ();
            section.add (name_row);
            section.add (auto_update_row);
            section.add (interval_row);
            return section;
        }

        private Adw.PreferencesGroup build_headers_group () {
            headers_group = new Adw.PreferencesGroup ();
            headers_group.title = "Request Headers";

            user_agent_row = new PresetEntryRow ("User Agent", group.user_agent, {
                PresetEntryRow.PresetItem ("Happ", "Happ/4.3/Android"),
                PresetEntryRow.PresetItem ("INCY", "INCY/3.9.9/Android"),
                PresetEntryRow.PresetItem ("v2rayN", "v2rayN/6.23"),
                PresetEntryRow.PresetItem ("Shadowrocket", "Shadowrocket/2.2.3"),
                PresetEntryRow.PresetItem ("Sing-box", "sing-box"),
                PresetEntryRow.PresetItem ("Vector (Default)", "Vector/" + Vector.Config.APP_VERSION)
            });
            headers_group.add (user_agent_row);


            string[] names, values;
            parse_headers (group.headers ?? "", out names, out values);
            for (int i = 0; i < names.length; i++) add_header_row (names[i], values[i]);

            var add_btn = Widgets.icon_label_button ("plus-symbolic", "Add Header");
            add_btn.clicked.connect (() => { add_header_row ("", ""); });
            headers_group.header_suffix = add_btn;
            return headers_group;
        }

        private void add_header_row (string name, string value) {
            var header = new HeaderRow ();
            header.name = new Gtk.Entry ();
            header.name.placeholder_text = "Header";
            header.name.text = name;
            header.name.hexpand = true;
            header.value = new Gtk.Entry ();
            header.value.placeholder_text = "Value";
            header.value.text = value;
            header.value.hexpand = true;

            var dash = new Gtk.Label ("-");
            dash.add_css_class ("dim-label");

            var fields = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            fields.hexpand = true;
            fields.valign = Gtk.Align.CENTER;
            fields.margin_top = 4;
            fields.margin_bottom = 4;
            fields.append (header.name);
            fields.append (dash);
            fields.append (header.value);

            header.row = new Adw.ActionRow ();
            header.row.activatable = false;
            header.row.add_prefix (fields);

            var remove_btn = Widgets.icon_button ("user-trash-symbolic", "Remove header");
            remove_btn.clicked.connect (() => {
                headers_group.remove (header.row);
                header_rows.remove (header);
            });
            header.row.add_suffix (remove_btn);

            headers_group.add (header.row);
            header_rows.add (header);
        }

        // parses semicolon or newline delimited "Name: value" (handles legacy "Name - value" format too)
        private static void parse_headers (string stored, out string[] names_out, out string[] values_out) {
            string[] names = {};
            string[] values = {};
            foreach (var raw in stored.replace (";", "\n").split ("\n")) {
                string line = raw.strip ();
                if (line == "") continue;
                string separator = line.contains (":") ? ":" : (line.contains (" - ") ? " - " : "");
                if (separator == "") {
                    names += line;
                    values += "";
                } else {
                    var parts = line.split (separator, 2);
                    names += parts[0].strip ();
                    values += parts[1].strip ();
                }
            }
            names_out = names;
            values_out = values;
        }

        private string format_headers () {
            string[] items = {};
            foreach (var header in header_rows) {
                string name = header.name.text.strip ();
                string value = header.value.text.strip ();
                if (name != "" && value != "") items += "%s: %s".printf (name, value);
                else if (name != "" || value != "") items += name + value;
            }
            return string.joinv ("; ", items);
        }

        private Adw.PreferencesGroup build_urls_group () {
            urls_group = new Adw.PreferencesGroup ();
            urls_group.title = "URLs";
            for (uint i = 0; i < group.urls.get_n_items (); i++) add_url_row (group.urls.get_string (i));
            if (group.urls.get_n_items () == 0) add_url_row ("");

            var add_btn = Widgets.icon_label_button ("plus-symbolic", "Add URL");
            add_btn.clicked.connect (() => { add_url_row (""); });
            urls_group.header_suffix = add_btn;
            return urls_group;
        }

        private void add_url_row (string url) {
            var row = new Adw.EntryRow ();
            row.title = "URL";
            row.text = url;
            var remove_btn = Widgets.icon_button ("user-trash-symbolic", "Remove URL");
            remove_btn.clicked.connect (() => {
                urls_group.remove (row);
                url_rows.remove (row);
            });
            row.add_suffix (remove_btn);
            urls_group.add (row);
            url_rows.add (row);
        }

        private void on_save () {
            string name = name_row.text.strip ();
            if (name == "") {
                name_row.add_css_class ("error");
                name_row.grab_focus ();
                return;
            }
            // manual nodes belong to group by name, update them if group renamed
            if (group.name != name) store.rename_manual_nodes (group.name, name);
            group.name = name;
            group.enable_update = auto_update_row.active;
            group.update_interval = int.max ((int) interval_row.value, MIN_INTERVAL);
            group.user_agent = user_agent_row.text.strip ();
            group.headers = format_headers ();

            store_urls.begin ();
        }

        // collect URLs and auto-decrypt any pasted happ:// links inline
        private async void store_urls () {
            group.urls.splice (0, group.urls.get_n_items (), null);
            foreach (var row in url_rows) {
                string url = row.text.strip ();
                if (url == "") continue;
                if (HappLink.is_happ_link (url)) {
                    try {
                        url = (yield HappLink.decrypt (url)).strip ();
                    } catch (HappLinkError e) {
                        row.add_css_class ("error");
                        continue;
                    }
                    if (!(url.has_prefix ("http://") || url.has_prefix ("https://"))) {
                        row.add_css_class ("error");
                        continue;
                    }
                }
                group.urls.append (url);
            }

            if (is_new) store.groups.append (group);
            store.save_subs ();
            store.save_nodes ();
            saved ();
            close ();
        }
    }
}
