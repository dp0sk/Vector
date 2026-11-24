using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        public void handle_paste () {
            var display = Gdk.Display.get_default ();
            var clipboard = display.get_clipboard ();
            clipboard.read_text_async.begin (null, (obj, res) => {
                try {
                    string text = clipboard.read_text_async.end (res);
                    if (text == null || text.strip () == "") return;
                    text = text.strip ();
                    if (text.has_prefix ("vpn://")) {
                        string? conf = Models.Node.amnezia_link_to_conf (text);
                        if (conf == null) {
                            show_toast (Models.Node.is_amnezia_api_link (text)
                                ? "This Amnezia link holds only an account key, not a server config. Export the connection from AmneziaVPN as an AmneziaWG .conf file."
                                : "Only WireGuard and AmneziaWG vpn:// links are supported.");
                            return;
                        }
                        add_wg_config (conf);
                        return;
                    }
                    if (Models.Node.looks_like_wg_conf (text)) {
                        add_wg_config (text);
                        return;
                    }

                    // raw xray json object or array (happ subscription payload)
                    if (text.strip ().has_prefix ("{") || text.strip ().has_prefix ("[")) {
                        var jns = SubscriptionManager.parse_config_body (text, "");
                        if (jns.length > 0) {
                            foreach (var jn in jns) {
                                assign_group_for_new_node (jn);
                                store.nodes.append (jn);
                            }
                            store.save_nodes ();
                            show_toast ("Added %d node(s) from config%s.".printf (jns.length, jns.length == 1 ? "" : "s"));
                            return;
                        }
                        if (text.strip ().has_prefix ("{")) {
                            show_toast ("Could not parse Xray config.");
                            return;
                        }
                    }

                    if (HappLink.is_happ_link (text)) {
                        handle_happ_link.begin (text);
                        return;
                    }

                    bool is_http = text.has_prefix ("http://") || text.has_prefix ("https://");
                    // http(s):// with user/pass is a proxy node, otherwise treat as subscription url
                    if (is_http && (Models.Node.from_link (text, "") == null || !(text.contains ("#") || text.contains ("@")))) {
                        var g = new SubGroup ("New Subscription");
                        g.urls.append (text);
                        store.groups.append (g);
                        store.save_subs ();
                        rebuild_subs_ui ();
                        rebuild_server_tabs ();
                        show_toast ("Added new subscription.");
                    } else {
                        var n = Models.Node.from_link (text, "");
                        if (n == null) {
                            show_toast ("Could not parse link.");
                            return;
                        }

                        assign_group_for_new_node (n);
                        store.nodes.append (n);
                        store.save_nodes ();
                        show_toast ("Added '%s'.".printf (n.name));
                    }
                } catch (GLib.Error e) {
                    show_toast ("Clipboard error: %s".printf (e.message));
                }
            });
        }

        // happ://crypt link: decrypts to sub url, single share link or newline-delimited base64 blob
        private async void handle_happ_link (string link) {
            string inner;
            try {
                inner = (yield HappLink.decrypt (link)).strip ();
            } catch (HappLinkError e) {
                show_toast ("Happ link: %s".printf (e.message));
                return;
            }
            if (inner.has_prefix ("http://") || inner.has_prefix ("https://")) {
                var g = new SubGroup ("Happ Subscription");
                g.urls.append (inner);
                store.groups.append (g);
                store.save_subs ();
                rebuild_subs_ui ();
                rebuild_server_tabs ();
                // fetch nodes right away: URL stays hidden so an empty group would look totally broken
                try {
                    int count = yield sub_mgr.update_one (inner, store, g, settings);
                    store.save_nodes ();
                    show_toast ("Happ: subscription added, %d node(s).".printf (count));
                } catch (GLib.Error e) {
                    show_toast ("Happ: subscription added, update failed (%s)".printf (e.message));
                }
                return;
            }

            // share link or lines of configs (possibly base64-encoded)
            string body = inner;
            if (Models.Node.from_link (body, "") == null) {
                string? decoded = Util.decode_b64 (body);
                if (decoded != null && decoded.contains ("://")) body = decoded;
            }
            var nodes = new GLib.GenericArray<Models.Node> ();
            foreach (var line in body.split ("\n")) {
                var n = Models.Node.from_link (line.strip (), "");
                if (n != null) nodes.add (n);
            }
            if (nodes.length == 0) {
                show_toast ("Happ link decrypted but holds no usable configs.");
                return;
            }
            foreach (var n in nodes) {
                assign_group_for_new_node (n);
                store.nodes.append (n);
            }
            store.save_nodes ();
            show_toast ("Happ: added %d node(s).".printf (nodes.length));
        }

        private void add_wg_config (string text) {
            string ignored;
            var nodes = Models.Node.from_wg_conf_all (text, "", out ignored);
            if (nodes.length == 0) {
                show_toast ("Not a usable WireGuard / AmneziaWG config (needs PrivateKey, PublicKey and Endpoint).");
                return;
            }
            for (uint i = 0; i < nodes.length; i++) {
                var n = nodes[i];
                if (ignored != "") append_log ("[app] '%s': ignored config keys: %s".printf (n.name, ignored));
                assign_group_for_new_node (n);
                store.nodes.append (n);
            }
            store.save_nodes ();
            if (nodes.length == 1) {
                show_toast ("Added '%s'.".printf (nodes[0].name));
            } else {
                show_toast ("Added %u WireGuard nodes.".printf (nodes.length));
            }
        }

        private async void import_wg_file () {
            var dialog = new Gtk.FileDialog ();
            dialog.title = "Import WireGuard / AmneziaWG Config";
            var filter = new Gtk.FileFilter ();
            filter.name = "WireGuard configs (*.conf)";
            filter.add_suffix ("conf");
            var filters = new GLib.ListStore (typeof (Gtk.FileFilter));
            filters.append (filter);
            dialog.filters = filters;
            dialog.default_filter = filter;
            try {
                var file = yield dialog.open (this, null);
                uint8[] contents;
                yield file.load_contents_async (null, out contents, null);
                var sb = new GLib.StringBuilder ();
                sb.append_len ((string) contents, contents.length);
                string text = sb.str;
                // derive node name from filename unless config has explicit "# name"
                string ignored;
                var nodes = Models.Node.from_wg_conf_all (text, "", out ignored);
                if (nodes.length == 0) {
                    show_toast ("Not a usable WireGuard / AmneziaWG config (needs PrivateKey, PublicKey and Endpoint).");
                    return;
                }
                string base_name = file.get_basename () ?? "";
                if (base_name.has_suffix (".conf")) base_name = base_name.substring (0, base_name.length - 5);
                bool has_name = text.down ().contains ("# name");
                for (uint i = 0; i < nodes.length; i++) {
                    var n = nodes[i];
                    if (base_name != "" && !has_name) {
                        if (nodes.length == 1) {
                            n.name = base_name;
                        } else {
                            n.name = "%s (%u)".printf (base_name, i + 1);
                        }
                    }
                    if (ignored != "") append_log ("[app] '%s': ignored config keys: %s".printf (n.name, ignored));
                    assign_group_for_new_node (n);
                    store.nodes.append (n);
                }
                store.save_nodes ();
                if (nodes.length == 1) {
                    show_toast ("Added '%s'.".printf (nodes[0].name));
                } else {
                    show_toast ("Added %u WireGuard nodes.".printf (nodes.length));
                }
            } catch (GLib.Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) show_toast ("Import failed: %s".printf (e.message));
            }
        }

        // assign node to active tab's group or fallback to "Manual"
        private void assign_group_for_new_node (Models.Node n) {
            SubGroup? current_group = null;
            var page = server_tabs.selected_page;
            if (page != null) {
                current_group = page.child.get_data<SubGroup> ("group");
            }
            if (current_group == null) {
                current_group = store.find_group ("Manual");
                if (current_group == null) {
                    current_group = new SubGroup ("Manual");
                    store.groups.append (current_group);
                    store.save_subs ();
                    rebuild_subs_ui ();
                    rebuild_server_tabs ();
                }
            }
            n.group_name = current_group.name;
            n.sub_url = current_group.urls.get_n_items () > 0 ? current_group.urls.get_string (0) : "";
        }

        private void handle_new_manual_node (string protocol) {
            var n = new Models.Node ();
            n.name = protocol == "awg" ? "New AmneziaWG" : "New Models.Node";
            n.protocol = protocol;
            if (n.is_wireguard ()) n.network = "udp";

            assign_group_for_new_node (n);

            var dialog = new NodeEditDialog (n, store);
            dialog.present (this);
            dialog.saved.connect (() => {
                store.nodes.append (n);
                store.save_nodes ();
                show_toast ("Added '%s'.".printf (n.name));
            });
        }

        private void remove_node (Models.Node n) {
            var dialog = new Adw.AlertDialog ("Delete Server Models.Node",
                "Are you sure you want to delete '%s'?".printf (n.name));
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("delete", "Delete");
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);

            dialog.response.connect ((d, response) => {
                if (response == "delete") {
                    if (n == active_node) active_node = null;
                    for (uint i = 0; i < store.nodes.get_n_items (); i++) {
                        if (store.nodes.get_item (i) == n) {
                            store.nodes.remove (i);
                            break;
                        }
                    }
                    store.save_nodes ();
                    update_active_label ();
                }
            });
            dialog.present (this);
        }

        private void show_node_context_menu (Models.Node n, Gtk.Widget anchor, double x, double y) {
            select_node_in_current_tab (n);

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.add_css_class ("node-menu");
            var popover = popover_at (anchor, x, y, box);

            add_menu_item (box, popover, "Edit", () => {
                var dialog = new NodeEditDialog (n, store);
                dialog.saved.connect (() => { on_node_edited (n); });
                dialog.present (this);
            });
            add_menu_item (box, popover, "Set as active", () => { set_active (n); });
            add_menu_item (box, popover, "Remove", () => { remove_node (n); }).add_css_class ("destructive-action");
            box.append (make_sep ());
            add_menu_item (box, popover, "Test Real Delay", () => { test_single_node.begin (n, false); });
            add_menu_item (box, popover, "Test Delay + Speed", () => { test_single_node.begin (n, true); });
            box.append (make_sep ());
            add_menu_item (box, popover, "Share (copy link)", () => { node_share_to_clipboard (n); });
            add_menu_item (box, popover, "QR Code", () => { node_show_qr (n); });
            box.append (make_sep ());
            add_menu_item (box, popover, "Export to Clipboard", () => { node_export_to_clipboard (n); });
            add_menu_item (box, popover, "Export to File", () => { node_export_to_file.begin (n); });

            // freeze pointer events on lists while popover is up so hover states don't freak out
            var list_item = anchor.get_parent ();
            if (list_item != null) list_item.add_css_class ("menu-open");
            foreach (var view in server_views) view.can_target = false;
            popover.closed.connect (() => {
                if (list_item != null) list_item.remove_css_class ("menu-open");
                foreach (var view in server_views) view.can_target = true;
                popover.unparent ();
            });
            popover.popup ();
        }

        private void select_node_in_current_tab (Models.Node n) {
            var page = server_tabs.selected_page;
            if (page == null) return;
            var selection = page.child.get_data<Gtk.SingleSelection> ("selection");
            if (selection == null) return;
            for (uint i = 0; i < selection.model.get_n_items (); i++) {
                if (selection.model.get_item (i) != n) continue;
                updating_ui = true;
                selection.selected = i;
                updating_ui = false;
                return;
            }
        }

        private void node_share_to_clipboard (Models.Node n) {
            string? link = n.to_link ();
            if (link == null) {
                show_toast (n.is_xray_json () ? "Share link not supported for this config." : "Share link not supported for %s.".printf (n.protocol));
                return;
            }
            Clipboard.copy (link);
            show_toast ("Share link copied to clipboard.");
        }

        private void node_show_qr (Models.Node n) {
            string? link = n.to_link ();
            if (link == null) {
                show_toast (n.is_xray_json () ? "QR code is not supported for full Xray JSON configs." : "QR not supported for %s.".printf (n.protocol));
                return;
            }
            show_qr_dialog ("Share", n.name, { link });
        }

        public void show_qr_dialog (string title, string subtitle, string[] links) {
            var pic = new Gtk.Picture ();
            pic.width_request  = 256;
            pic.height_request = 256;
            pic.can_shrink = true;
            pic.halign = Gtk.Align.CENTER;

            var lbl = new Gtk.Label ("");
            lbl.wrap       = true;
            lbl.wrap_mode  = Pango.WrapMode.CHAR;
            lbl.selectable = true;
            lbl.max_width_chars = 36;
            lbl.add_css_class ("monospace");
            lbl.add_css_class ("caption");
            lbl.add_css_class ("dim-label");

            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            scroll.max_content_height = 80;
            scroll.propagate_natural_height = true;
            scroll.child = lbl;

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_top    = 16;
            content.margin_bottom = 20;
            content.margin_start  = 20;
            content.margin_end    = 20;
            content.halign = Gtk.Align.CENTER;

            if (links.length > 1) {
                string[] shown = {};
                foreach (var l in links) shown += l.length > 50 ? l.substring (0, 47) + "..." : l;
                var picker = new Gtk.DropDown (Widgets.string_list (shown), null);
                string[] choices = links; // closure capture outlives caller array
                picker.notify["selected"].connect (() => { load_qr (choices[picker.selected], pic, lbl); });
                content.append (picker);
            }
            content.append (pic);
            content.append (scroll);
            load_qr (links[0], pic, lbl);

            var header = new Adw.HeaderBar ();
            header.title_widget = new Adw.WindowTitle (title, subtitle);
            header.show_back_button = false;

            var tb = new Adw.ToolbarView ();
            tb.add_top_bar (header);
            tb.content = content;

            var dlg = new Adw.Dialog ();
            dlg.child         = tb;
            dlg.content_width = 340;
            dlg.present (this);
        }

        private void load_qr (string link, Gtk.Picture pic, Gtk.Label lbl) {
            lbl.label = link;
            try {
                pic.paintable = QrCode.texture (link);
            } catch (GLib.Error e) {
                show_toast ("Could not make the QR code: %s".printf (e.message));
            }
        }

        private void node_export_to_clipboard (Models.Node n) {
            var active_preset = store.get_active_routing_preset ();
            string cfg = engine_core_for (n) == "xray"
                ? ConfigGenerator.gen_xray (n, settings, active_preset)
                : ConfigGenerator.gen_singbox (n, settings, active_preset);
            Clipboard.copy (cfg);
            show_toast ("Full config copied to clipboard.");
        }

        private async void node_export_to_file (Models.Node n) {
            var active_preset = store.get_active_routing_preset ();
            string cfg = engine_core_for (n) == "xray"
                ? ConfigGenerator.gen_xray (n, settings, active_preset)
                : ConfigGenerator.gen_singbox (n, settings, active_preset);

            var dialog = new Gtk.FileDialog ();
            dialog.title = "Export Config";
            dialog.initial_name = "%s.json".printf (n.name.replace ("/", "_"));
            var json_filter = new Gtk.FileFilter ();
            json_filter.name = "JSON files";
            json_filter.add_suffix ("json");
            dialog.default_filter = json_filter;

            try {
                var file = yield dialog.save (this, null);
                if (file == null) return;
                file.replace_contents (cfg.data, null, false,
                    GLib.FileCreateFlags.REPLACE_DESTINATION, null, null);
                show_toast ("Config exported to %s.".printf (file.get_basename ()));
            } catch (GLib.Error e) {
                if (!(e is GLib.IOError.CANCELLED))
                    show_toast ("Export failed: %s".printf (e.message));
            }
        }
    }
}
