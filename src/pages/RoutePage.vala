using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private const string[] XRAY_STRATEGIES = { "AsIs", "IPIfNonMatch", "IPOnDemand" };
        private const string[] XRAY_STRATEGY_LABELS = { "AsIs", "IPIfNonMatch", "IPOnDemand" };
        private const string[] IP_MODE_LABELS = { "Prefer IPv4", "Prefer IPv6", "Don't Use IPv6" };

        private Adw.ComboRow xray_strategy_row;
        private Adw.PreferencesGroup presets_group;
        private GLib.GenericArray<Adw.ActionRow> preset_rows = new GLib.GenericArray<Adw.ActionRow> ();

        private Gtk.Widget build_route_page () {
            var page = new Adw.PreferencesPage ();
            page.add (build_strategy_group ());
            page.add (build_presets_group ());
            page.add (build_bypass_group ());
            page.add (build_dns_group ());
            return page;
        }

        private Adw.PreferencesGroup build_strategy_group () {
            xray_strategy_row = new Adw.ComboRow ();
            xray_strategy_row.title = "xray";
            xray_strategy_row.model = Widgets.string_list (XRAY_STRATEGY_LABELS);
            xray_strategy_row.notify["selected"].connect (() => {
                if (updating_ui) return;
                var preset = store.get_active_routing_preset ();
                if (preset == null) return;
                preset.domain_strategy = XRAY_STRATEGIES[xray_strategy_row.selected];
                store.save_routing ();
                notify_config_changed ();
            });

            show_preset_strategies (store.get_active_routing_preset ());

            var group = new Adw.PreferencesGroup ();
            group.title = "Domain Strategy";
            group.add (xray_strategy_row);
            group.add (build_ip_mode_row ());
            return group;
        }

        // ipv6 preference for dns lookups or disable v6 completely
        private Adw.ComboRow build_ip_mode_row () {
            var row = new Adw.ComboRow ();
            row.title = "IPv6";
            row.model = Widgets.string_list (IP_MODE_LABELS);
            row.selected = strategy_index (AppSettings.IP_MODES, AppSettings.IP_MODES, settings.ip_mode);
            row.notify["selected"].connect (() => {
                settings.ip_mode = AppSettings.IP_MODES[row.selected];
                settings.save ();
                notify_config_changed ();
            });
            return row;
        }

        private void show_preset_strategies (RoutingPreset? preset) {
            if (preset == null) return;
            bool was_updating = updating_ui;
            updating_ui = true; // prevent setting combo index from triggering notify::selected loop
            xray_strategy_row.selected = strategy_index (XRAY_STRATEGIES, XRAY_STRATEGY_LABELS, preset.domain_strategy);
            updating_ui = was_updating;
        }

        private static uint strategy_index (string[] values, string[] labels, string value) {
            for (uint i = 0; i < values.length; i++) {
                if (values[i] == value || labels[i] == value) return i;
            }
            return 0;
        }

        private Adw.PreferencesGroup build_presets_group () {
            presets_group = new Adw.PreferencesGroup ();
            presets_group.title = "Presets";

            var fetch_btn = Widgets.icon_label_button ("arrow-clockwise-symbolic", "Fetch");
            fetch_btn.tooltip_text = "Download presets from the rules source";
            fetch_btn.clicked.connect (() => {
                fetch_btn.sensitive = false;
                fetch_routing_rules_async.begin ((obj, res) => {
                    fetch_btn.sensitive = true;
                    refresh_presets_list ();
                });
            });

            var add_btn = Widgets.icon_label_button ("plus-symbolic", "Add");
            add_btn.clicked.connect (() => {
                var preset = new RoutingPreset ("New Routing Preset");
                store.routing_presets.append (preset);
                store.save_routing ();
                refresh_presets_list ();
                open_preset_editor (preset);
            });

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            buttons.valign = Gtk.Align.CENTER;
            buttons.append (fetch_btn);
            buttons.append (add_btn);
            presets_group.header_suffix = buttons;

            refresh_presets_list ();
            return presets_group;
        }

        private void refresh_presets_list () {
            foreach (var row in preset_rows) presets_group.remove (row);
            preset_rows.remove_range (0, preset_rows.length);

            Gtk.CheckButton? radio_group = null;
            for (uint i = 0; i < store.routing_presets.get_n_items (); i++) {
                var preset = (RoutingPreset) store.routing_presets.get_item (i);
                var row = build_preset_row (preset, ref radio_group);
                presets_group.add (row);
                preset_rows.add (row);
            }
        }

        private Adw.ActionRow build_preset_row (RoutingPreset preset, ref Gtk.CheckButton? radio_group) {
            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = preset.name != "" ? preset.name : "Unnamed Preset";
            uint n_rules = preset.rules.get_n_items ();
            row.subtitle = n_rules == 1 ? "1 rule" : "%u rules".printf (n_rules);

            var radio = new Gtk.CheckButton ();
            if (radio_group != null) radio.set_group (radio_group);
            else radio_group = radio;
            radio.active = preset.is_active;
            radio.valign = Gtk.Align.CENTER;
            radio.toggled.connect (() => {
                if (!radio.active) return;
                store.set_active_routing_preset (preset);
                show_preset_strategies (preset);
                notify_config_changed ();
            });

            var edit_btn = Widgets.icon_button ("pencil-symbolic", "Edit rules");
            edit_btn.clicked.connect (() => { open_preset_editor (preset); });

            var del_btn = Widgets.icon_button ("user-trash-symbolic", "Delete preset");
            del_btn.clicked.connect (() => {
                Widgets.confirm_delete (this, "Delete Preset",
                    "Are you sure you want to delete preset '%s'?".printf (preset.name), () => {
                        delete_preset (preset);
                    });
            });

            row.add_prefix (radio);
            row.add_suffix (edit_btn);
            row.add_suffix (del_btn);
            return row;
        }

        private void open_preset_editor (RoutingPreset preset) {
            var dialog = new RoutingDialog (store, preset);
            dialog.routing_changed.connect (() => {
                refresh_presets_list ();
                notify_config_changed ();
            });
            dialog.present (this);
        }

        private void delete_preset (RoutingPreset preset) {
            uint pos;
            if (!store.routing_presets.find (preset, out pos)) return;
            store.routing_presets.remove (pos);
            store.save_routing ();
            refresh_presets_list ();
            notify_config_changed ();
        }

        private async void fetch_routing_rules_async () {
            string source_url = settings.routing_rules_source.strip ();
            if (source_url == "") source_url = RoutingRulesFetcher.DEFAULT_SOURCE;
            show_toast ("Fetching routing rules from remote source...");
            append_log ("[app] fetching routing rules index from %s".printf (source_url));

            var fetcher = new RoutingRulesFetcher ();
            fetcher.log_line.connect (append_log);
            GLib.GenericArray<RoutingPreset> presets;
            try {
                presets = yield fetcher.fetch (source_url);
            } catch (GLib.Error e) {
                show_toast ("Failed to fetch routing rules from source");
                append_log ("[app] fetching routing rules failed: %s".printf (e.message));
                return;
            }
            if (presets.length == 0) {
                show_toast ("No valid routing rules found in source");
                return;
            }
            uint rules = 0;
            foreach (var p in presets) {
                store.add_or_update_preset (p);
                rules += p.rules.get_n_items ();
                append_log ("[app] preset '%s': %u rules".printf (p.name, p.rules.get_n_items ()));
            }
            store.save_routing ();
            notify_config_changed ();
            show_toast ("Updated %u preset(s) with %u rule(s)".printf (presets.length, rules));
        }

        private Adw.PreferencesGroup build_bypass_group () {
            var lan_row = new Adw.SwitchRow ();
            lan_row.title = "Local Network";
            Widgets.bind_switch (lan_row, settings, "bypass_lan");
            settings.notify["bypass-lan"].connect (() => notify_config_changed ());

            var group = new Adw.PreferencesGroup ();
            group.title = "Bypass the Proxy";
            group.description = "Comma-separated";
            group.add (lan_row);
            group.add (setting_entry_row ("IPs and CIDRs", settings.bypass_ips, (v) => { settings.bypass_ips = v; }));
            group.add (setting_entry_row ("Domains", settings.bypass_domains, (v) => { settings.bypass_domains = v; }));
            return group;
        }

        private Adw.PreferencesGroup build_dns_group () {
            var group = new Adw.PreferencesGroup ();
            group.title = "DNS";
            group.description = "IP, tls:// or https:// address";
            group.add (setting_entry_row ("Remote DNS (via proxy)", settings.remote_dns,
                                          (v) => { settings.remote_dns = v.strip (); }));
            group.add (setting_entry_row ("Direct DNS", settings.direct_dns,
                                          (v) => { settings.direct_dns = v.strip (); }));
            return group;
        }

        // entry row helper that auto-saves to settings and flags config reload
        private Adw.EntryRow setting_entry_row (string title, string value, owned StringSetting store_value) {
            var row = new Adw.EntryRow ();
            row.title = title;
            row.text = value;
            row.changed.connect (() => {
                store_value (row.text);
                settings.save ();
                notify_config_changed ();
            });
            return row;
        }
    }
}
