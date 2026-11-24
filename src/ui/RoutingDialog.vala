using Vector.Models;
using Vector.Routing;
using Vector.Services;
namespace Vector.Ui {

    // multi-page preset editor: root page reorders/deletes rules, drill-down pushes child page to tweak rule properties
    public class RoutingDialog : Adw.Dialog {

        public signal void routing_changed ();

        private Store store;
        private RoutingPreset preset;
        private Adw.NavigationView nav_view;
        private Adw.WindowTitle preset_title;
        private Adw.PreferencesGroup rules_group;
        private GLib.GenericArray<Adw.ActionRow> rule_rows = new GLib.GenericArray<Adw.ActionRow> ();

        private const string[] OUTBOUNDS = { "proxy", "direct", "block" };
        private const string[] NETWORKS = { "", "tcp", "udp" };
        private const string[] NETWORK_LABELS = { "All", "tcp", "udp" };
        private const string[] PROTOCOLS = { "http", "tls", "quic", "bittorrent" };
        private const string[] PROTOCOL_LABELS = { "HTTP", "TLS", "QUIC", "BitTorrent" };
        private const string[] INBOUNDS = { "tun", "socks", "socks2", "socks3" };
        private const string[] INBOUND_LABELS = { "TUN", "SOCKS", "SOCKS2", "SOCKS3" };

        public RoutingDialog (Store store, RoutingPreset preset) {
            this.store = store;
            this.preset = preset;
            title = "Edit Preset";
            content_width = 640;
            content_height = 700;

            nav_view = new Adw.NavigationView ();
            child = nav_view;
            nav_view.push (build_preset_page ());
        }

        private void changed () {
            store.save_routing ();
            routing_changed ();
        }

        private Adw.NavigationPage build_preset_page () {
            preset_title = new Adw.WindowTitle ("Edit Preset", preset.name);

            var name_row = new Adw.EntryRow ();
            name_row.title = "Name";
            name_row.text = preset.name;
            name_row.changed.connect (() => {
                preset.name = name_row.text.strip ();
                preset_title.subtitle = preset.name;
                changed ();
            });
            var name_group = new Adw.PreferencesGroup ();
            name_group.add (name_row);

            rules_group = new Adw.PreferencesGroup ();
            rules_group.title = "Rules";
            rules_group.description = "Applied top to bottom";
            var add_btn = Widgets.icon_label_button ("plus-symbolic", "Add Rule");
            add_btn.clicked.connect (() => {
                var rule = new RoutingRule ("New Rule", "proxy");
                preset.rules.append (rule);
                changed ();
                refresh_rules_list ();
                nav_view.push (build_rule_page (rule));
            });
            rules_group.header_suffix = add_btn;
            refresh_rules_list ();

            var page = new Adw.PreferencesPage ();
            page.add (name_group);
            page.add (rules_group);

            // edits auto-save immediately, Done button just closes modal
            var done_btn = new Gtk.Button.with_label ("Done");
            done_btn.clicked.connect (() => { close (); });
            var header = DialogHeader.create ("", "", done_btn, null);
            header.title_widget = preset_title;

            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (header);
            toolbar.content = page;
            return new Adw.NavigationPage (toolbar, "preset_editor");
        }

        private void refresh_rules_list () {
            foreach (var row in rule_rows) rules_group.remove (row);
            rule_rows.remove_range (0, rule_rows.length);
            for (uint i = 0; i < preset.rules.get_n_items (); i++) {
                var row = build_rule_row ((RoutingRule) preset.rules.get_item (i), i);
                rules_group.add (row);
                rule_rows.add (row);
            }
        }

        // "outbound: direct • net: tcp • domain rules"
        private static string rule_summary (RoutingRule rule) {
            string text = "outbound: %s".printf (rule.outbound_tag);
            if (rule.network != "") text += " • net: %s".printf (rule.network);
            if (rule.protocol != "") text += " • proto: %s".printf (rule.protocol);
            if (rule.domains != "") text += " • domain rules";
            if (rule.ips != "") text += " • IP rules";
            if (rule.processes != "") text += " • process rules";
            return text;
        }

        private Adw.ActionRow build_rule_row (RoutingRule rule, uint index) {
            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = rule.remarks != "" ? rule.remarks : "Rule #%u".printf (index + 1);
            row.subtitle = rule_summary (rule);

            var handle = new Gtk.Image.from_icon_name ("list-drag-handle-symbolic");
            handle.add_css_class ("dim-label");
            handle.valign = Gtk.Align.CENTER;
            handle.margin_end = 8;
            row.add_prefix (handle);
            make_rule_row_draggable (row, rule);

            var enabled = new Gtk.Switch ();
            enabled.active = rule.enabled;
            enabled.valign = Gtk.Align.CENTER;
            enabled.notify["active"].connect (() => {
                rule.enabled = enabled.active;
                changed ();
            });
            row.add_prefix (enabled);

            var edit_btn = Widgets.icon_button ("pencil-symbolic", "Edit rule");
            edit_btn.clicked.connect (() => { nav_view.push (build_rule_page (rule)); });
            var delete_btn = Widgets.icon_button ("user-trash-symbolic", "Delete rule");
            delete_btn.clicked.connect (() => {
                Widgets.confirm_delete (this, "Delete Rule", "Are you sure you want to delete this routing rule?", () => {
                    uint position;
                    if (preset.rules.find (rule, out position)) {
                        preset.rules.remove (position);
                        changed ();
                        refresh_rules_list ();
                    }
                });
            });
            row.add_suffix (edit_btn);
            row.add_suffix (delete_btn);
            return row;
        }

        // DnD reordering for routing rule rows
        private void make_rule_row_draggable (Adw.ActionRow row, RoutingRule rule) {
            var source = new Gtk.DragSource ();
            source.set_actions (Gdk.DragAction.MOVE);
            source.prepare.connect ((x, y) => {
                var value = GLib.Value (typeof (RoutingRule));
                value.set_object (rule);
                return new Gdk.ContentProvider.for_value (value);
            });
            source.drag_begin.connect ((drag) => {
                var title = new Gtk.Label (row.title);
                title.halign = Gtk.Align.START;
                title.add_css_class ("heading");
                var subtitle = new Gtk.Label (row.subtitle);
                subtitle.halign = Gtk.Align.START;
                subtitle.add_css_class ("dim-label");
                var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
                card.add_css_class ("drag-icon-card");
                card.append (title);
                card.append (subtitle);
                ((Gtk.DragIcon) Widgets.drag_icon_for (drag)).child = card;
            });
            row.add_controller (source);

            var target = new Gtk.DropTarget (typeof (RoutingRule), Gdk.DragAction.MOVE);
            target.drop.connect ((value, x, y) => {
                var dragged = value.get_object () as RoutingRule;
                if (dragged == null || dragged == rule) return false;
                uint position;
                if (!preset.rules.find (rule, out position)) return false;
                preset.move_rule (dragged, (int) position);
                changed ();
                refresh_rules_list ();
                return true;
            });
            row.add_controller (target);
        }

        private Adw.NavigationPage build_rule_page (RoutingRule rule) {
            var name_row = new Adw.EntryRow ();
            name_row.title = "Name";
            name_row.text = rule.remarks;

            var enabled_row = new Adw.SwitchRow ();
            enabled_row.title = "Enabled";
            enabled_row.active = rule.enabled;

            var outbound_row = choice_row ("Outbound", OUTBOUNDS, OUTBOUNDS, rule.outbound_tag);
            var network_row = choice_row ("Network", NETWORKS, NETWORK_LABELS, rule.network);

            var port_row = new Adw.SpinRow.with_range (0, 65535, 1);
            port_row.title = "Port";
            port_row.value = double.parse (rule.port);

            var protocols = new TagToggles (PROTOCOLS, PROTOCOL_LABELS, rule.protocol);
            var inbounds = new TagToggles (INBOUNDS, INBOUND_LABELS, rule.inbound_tag);

            var main_group = new Adw.PreferencesGroup ();
            main_group.add (name_row);
            main_group.add (enabled_row);
            main_group.add (outbound_row);
            main_group.add (network_row);
            main_group.add (port_row);
            main_group.add (protocols.as_row ("Protocol"));
            main_group.add (inbounds.as_row ("Inbound"));

            var page = new Adw.PreferencesPage ();
            page.add (main_group);
            var domains = add_list_editor (page, "Domains", "One per line or comma-separated, e.g. geosite:category-ads-all", rule.domains);
            var ips = add_list_editor (page, "IPs and CIDRs", "e.g. geoip:private, 192.168.1.0/24", rule.ips);
            var processes = add_list_editor (page, "Processes", "One name per line", rule.processes);

            var save_btn = new Gtk.Button.with_label ("Save");
            save_btn.clicked.connect (() => {
                rule.remarks = name_row.text.strip ();
                rule.enabled = enabled_row.active;
                rule.outbound_tag = OUTBOUNDS[outbound_row.selected];
                rule.network = NETWORKS[network_row.selected];
                int port = (int) port_row.value;
                rule.port = port > 0 ? port.to_string () : "";
                rule.protocol = protocols.to_list ();
                rule.inbound_tag = inbounds.to_list ();
                rule.domains = domains.buffer.text.strip ();
                rule.ips = ips.buffer.text.strip ();
                rule.processes = processes.buffer.text.strip ();
                changed ();
                refresh_rules_list ();
                nav_view.pop ();
            });

            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (DialogHeader.create ("Edit Rule", rule.remarks, save_btn,
                                                      () => { nav_view.pop (); }));
            toolbar.content = page;
            return new Adw.NavigationPage (toolbar, "rule_editor");
        }

        private static Adw.ComboRow choice_row (string title, string[] values, string[] labels, string current) {
            var row = new Adw.ComboRow ();
            row.title = title;
            row.model = Widgets.string_list (labels);
            for (uint i = 0; i < values.length; i++) {
                if (values[i] == current) row.selected = i;
            }
            return row;
        }

        private static Gtk.TextView add_list_editor (Adw.PreferencesPage page, string title, string hint, string text) {
            var view = new Gtk.TextView ();
            view.wrap_mode = Gtk.WrapMode.WORD;
            view.buffer.text = text;
            view.top_margin = 8;
            view.bottom_margin = 8;
            view.left_margin = 8;
            view.right_margin = 8;

            var scroll = new Gtk.ScrolledWindow ();
            scroll.min_content_height = 120;
            scroll.child = view;
            scroll.add_css_class ("editor-card");

            var group = new Adw.PreferencesGroup ();
            group.title = title;
            group.description = hint;
            group.add (scroll);
            page.add (group);
            return view;
        }

        // button group helper for comma-separated list values ("http, tls")
        private class TagToggles : GLib.Object {
            private string[] values;
            private Gtk.ToggleButton[] buttons = {};

            public TagToggles (string[] values, string[] labels, string current) {
                this.values = values;
                var selected = new GLib.GenericSet<string> (str_hash, str_equal);
                foreach (var part in current.split (",")) selected.add (part.strip ().down ());
                for (int i = 0; i < values.length; i++) {
                    var btn = new Gtk.ToggleButton.with_label (labels[i]);
                    btn.add_css_class ("flat");
                    btn.active = selected.contains (values[i]);
                    buttons += btn;
                }
            }

            public Adw.ActionRow as_row (string title) {
                var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
                box.valign = Gtk.Align.CENTER;
                box.add_css_class ("toggle-group");
                foreach (var btn in buttons) box.append (btn);
                var row = new Adw.ActionRow ();
                row.title = title;
                row.add_suffix (box);
                return row;
            }

            public string to_list () {
                string[] on = {};
                for (int i = 0; i < buttons.length; i++) {
                    if (buttons[i].active) on += values[i];
                }
                return string.joinv (", ", on);
            }
        }
    }
}
