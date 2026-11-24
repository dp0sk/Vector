using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private Adw.ComboRow core_row;
        // per-protocol combo models: first item is always whatever Default resolves to
        private GLib.HashTable<string, Gtk.StringList> protocol_models =
            new GLib.HashTable<string, Gtk.StringList> (str_hash, str_equal);

        private const string[] DEFAULT_CORES = { "sing-box", "xray" };

        private Gtk.Widget build_core_page () {
            var page = new Adw.PreferencesPage ();
            page.add (build_general_group ());
            page.add (build_protocol_cores_group ());
            return page;
        }

        private Adw.PreferencesGroup build_general_group () {
            var tunnel_bg_row = new Adw.SwitchRow ();
            tunnel_bg_row.title = "Stay Connected After Exit";
            Widgets.bind_switch (tunnel_bg_row, settings, "run_tunnel_in_background");

            var app_bg_row = new Adw.SwitchRow ();
            app_bg_row.title = "Close to Tray";
            Widgets.bind_switch (app_bg_row, settings, "run_app_in_background");

            core_row = new Adw.ComboRow ();
            core_row.title = "Default Core";
            core_row.model = Widgets.string_list (DEFAULT_CORES);
            core_row.selected = settings.core == "xray" ? 1 : 0;
            core_row.notify["selected"].connect (() => {
                if (updating_ui) return;
                switch_core.begin (DEFAULT_CORES[core_row.selected]);
            });

            var group = new Adw.PreferencesGroup ();
            group.title = "General";
            group.add (tunnel_bg_row);
            group.add (app_bg_row);
            group.add (core_row);
            add_port_rows (group);
            return group;
        }

        // desktop proxy port: fixed or grab a fresh random port on connect
        private void add_port_rows (Adw.PreferencesGroup group) {
            var random_port_row = new Adw.SwitchRow ();
            random_port_row.title = "Random Port";
            random_port_row.subtitle = "A free port on every connect";
            random_port_row.active = settings.random_mixed_port;

            var port_row = new Adw.SpinRow.with_range (1024, 65535, 1);
            port_row.title = "Proxy Port";
            port_row.value = settings.mixed_port;

            Widgets.bind_switch (random_port_row, settings, "random_mixed_port");
            Widgets.bind_setting (port_row, "value", settings, "mixed_port");
            settings.notify["random_mixed_port"].connect (() => {
                port_row.sensitive = !settings.random_mixed_port;
                notify_config_changed ();
            });
            settings.notify["mixed_port"].connect (() => notify_config_changed ());

            group.add (random_port_row);
            group.add (port_row);
        }

        // protocol core overrides: if only one core can handle it (like xhttp on xray), just disable the row
        private Adw.PreferencesGroup build_protocol_cores_group () {
            var group = new Adw.PreferencesGroup ();
            group.title = "Core per Protocol";
            foreach (var key in Cores.PROTOCOL_KEYS) {
                string[] allowed = Cores.cores_for_key (key);
                group.add (allowed.length == 1 ? fixed_core_row (key, allowed[0]) : protocol_core_row (key, allowed));
            }
            return group;
        }

        // disable row if no choice exists; ComboRow looks like ass here and ellipsizes the text
        private Adw.ActionRow fixed_core_row (string key, string core) {
            var row = new Adw.ActionRow ();
            row.title = Cores.label_for_key (key);
            row.add_suffix (new Gtk.Label ("Protocol default (%s)".printf (core)));
            row.sensitive = false;
            return row;
        }

        private Adw.ComboRow protocol_core_row (string key, string[] allowed) {
            string[] items = { default_core_item (key) };
            foreach (var c in allowed) items += c;
            var model = Widgets.string_list (items);
            protocol_models.insert (key, model);

            var row = new Adw.ComboRow ();
            row.title = Cores.label_for_key (key);
            row.model = model;
            string? chosen = settings.protocol_cores.lookup (key);
            row.selected = 0;
            for (int i = 0; i < allowed.length; i++) if (allowed[i] == chosen) row.selected = i + 1;

            // closure outlives stack frame: copy string and array
            string protocol = key;
            string[] cores = allowed;
            row.notify["selected"].connect (() => {
                if (updating_ui) return;
                if (row.selected == 0) settings.protocol_cores.remove (protocol);
                else settings.protocol_cores.insert (protocol, cores[row.selected - 1]);
                settings.save ();
                apply_engine_change ();
            });
            return row;
        }

        private string default_core_item (string key) {
            return "Default (%s)".printf (Cores.default_core_for_key (key, settings));
        }

        private void refresh_protocol_rows () {
            bool prev = updating_ui;
            updating_ui = true; // splice() triggers notify::selected so guard against bogus engine restart
            protocol_models.foreach ((key, model) => {
                model.splice (0, 1, { default_core_item (key) });
            });
            updating_ui = prev;
        }
    }
}
