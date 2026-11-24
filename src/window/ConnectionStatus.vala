using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private bool checking_status = false;
        private GLib.Cancellable? status_cancellable = null;
        private uint status_check_id = 0; // bump check ID so stale async results don't clobber newer ones
        // cache exit IP -> ISO country code so we don't spam lookups
        private GLib.HashTable<string, string> ip_country = new GLib.HashTable<string, string> (str_hash, str_equal);

        private void set_active (Models.Node? n) {
            if (active_node != null)
                active_node.is_active = false;

            active_node = n;

            if (n != null) {
                n.is_active = true;
                settings.active_node_id = n.get_id ();
                settings.save ();
            }
            update_active_label ();
        }

        private Models.Node? find_node_from_config () {
            return find_node_in_config (Paths.engine_json ());
        }

        // dig out server/port/secret from proxy outbound in config
        private static bool proxy_server_of (Json.Object ob, out string addr, out int port, out string secret) {
            addr = ""; port = 0; secret = "";
            if (ob.has_member ("server")) { // sing-box
                addr = Util.j_str (ob, "server");
                port = Util.j_int (ob, "server_port");
                secret = ob.has_member ("uuid") ? Util.j_str (ob, "uuid") : Util.j_str (ob, "password");
                return addr != "";
            }
            if (!ob.has_member ("settings")) return false; // xray
            var st = ob.get_object_member ("settings");
            foreach (var list in new string[] { "vnext", "servers" }) {
                if (!st.has_member (list)) continue;
                var arr = st.get_array_member (list);
                if (arr.get_length () == 0) continue;
                var srv = arr.get_object_element (0);
                addr = Util.j_str (srv, "address");
                port = Util.j_int (srv, "port");
                secret = Util.j_str (srv, "password");
                if (srv.has_member ("users") && srv.get_array_member ("users").get_length () > 0) {
                    secret = Util.j_str (srv.get_array_member ("users").get_object_element (0), "id");
                }
                return addr != "";
            }
            return false;
        }

        private Models.Node? find_node_in_config (string cfg_path) {
            if (!GLib.FileUtils.test (cfg_path, GLib.FileTest.EXISTS)) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (cfg_path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return null;
                var obj = root.get_object ();
                if (!obj.has_member ("outbounds")) return null;
                var outbounds = obj.get_array_member ("outbounds");
                for (uint i = 0; i < outbounds.get_length (); i++) {
                    var ob = outbounds.get_object_element (i);
                    if (ob == null || Util.j_str (ob, "tag") != "proxy") continue;
                    // auto node "proxy" is a urltest group with no server of its own, dig into member outbounds
                    if (ob.has_member ("type") && ob.has_member ("outbounds")) {
                        var members = ob.get_array_member ("outbounds");
                        for (uint m = 0; m < members.get_length (); m++) {
                            string mt = members.get_string_element (m);
                            for (uint j = 0; j < outbounds.get_length (); j++) {
                                var mob = outbounds.get_object_element (j);
                                if (mob == null || Util.j_str (mob, "tag") != mt) continue;
                                string maddr, msecret;
                                int mport;
                                if (!proxy_server_of (mob, out maddr, out mport, out msecret)) continue;
                                for (uint n = 0; n < store.nodes.get_n_items (); n++) {
                                    var node = (Models.Node) store.nodes.get_item (n);
                                    if (node.uuid != msecret) continue;
                                    if (node.address == maddr || node.auto_hosts.contains (maddr)) return node;
                                }
                            }
                        }
                        return null;
                    }
                    string addr, secret;
                    int port;
                    if (!proxy_server_of (ob, out addr, out port, out secret)) return null;
                    Models.Node? by_addr = null;
                    for (uint n = 0; n < store.nodes.get_n_items (); n++) {
                        var node = (Models.Node) store.nodes.get_item (n);
                        if (node.address != addr) continue;
                        if ((port == 0 || node.port == port) && (secret == "" || node.uuid == secret)) return node;
                        if (by_addr == null) by_addr = node;
                    }
                    return by_addr;
                }
            } catch (GLib.Error e) {
                // invalid/corrupt json: bail
            }
            return null;
        }

        public void restore_active_node_state () {
            if (active_node == null && settings.active_node_id != "") {
                for (uint i = 0; i < store.nodes.get_n_items (); i++) {
                    var node = (Models.Node) store.nodes.get_item (i);
                    if (node.get_id () == settings.active_node_id) {
                        active_node = node;
                        break;
                    }
                }
            }

            // sub update broke node ID under our feet: recover it from running engine config
            if (active_node == null) {
                active_node = find_node_from_config ();
            }

            if (active_node != null) {
                active_node.is_active = true;
                settings.active_node_id = active_node.get_id ();
                settings.save ();
            }

            if (active_label != null) {
                update_active_label ();
            }
        }

        private void update_active_label () {
            if (active_node != null) {
                active_label.label = active_node.name;
                active_label.remove_css_class ("dim-label");
                if (runner.running) {
                    if (checking_status) {
                        ip_label.label = "Checking\u2026";
                    } else if (ip_label.label == "" || ip_label.label == "Not connected") {
                        ip_label.label = "Connected";
                    }
                } else {
                    ip_label.label = "Not connected";
                }
            } else {
                active_label.label = "No server selected";
                active_label.add_css_class ("dim-label");
                ip_label.label = "Not connected";
            }
            if (locate_btn != null) {
                locate_btn.sensitive = (active_node != null);
            }
        }

        // 2-letter ISO country code or empty
        private void show_ip_country (string country) {
            country_label.label = country;
            country_label.visible = country != "";
        }

        private async void check_connection_status (bool is_recheck = false) {
            if (!runner.running || active_node == null) {
                if (status_cancellable != null) {
                    status_cancellable.cancel ();
                    status_cancellable = null;
                }
                checking_status = false;
                ip_label.label = "Not connected";
                return;
            }

            if (status_cancellable != null) {
                status_cancellable.cancel ();
                status_cancellable = null;
            }

            var cancellable = new GLib.Cancellable ();
            status_cancellable = cancellable;
            uint check_id = ++status_check_id;
            checking_status = true;
            ip_label.label = "Checking\u2026";

            try {
                if (!is_recheck) {
                    bool port_open = yield Tester.wait_for_port ((uint16) settings.current_mixed_port, 25, cancellable);
                    if (check_id != status_check_id || cancellable.is_cancelled ()) return;
                    if (!port_open) {
                        ip_label.label = "Core not responding";
                        return;
                    }
                }

                if (active_node == null || !runner.running) {
                    ip_label.label = "Not connected";
                    return;
                }

                int latency = yield Tester.probe_latency ((uint16) settings.current_mixed_port, settings.ping_url, settings.test_timeout, cancellable);
                if (check_id != status_check_id || cancellable.is_cancelled ()) return;

                if (active_node == null || !runner.running) {
                    ip_label.label = "Not connected";
                    return;
                }

                if (latency > 0) {
                    active_node.latency = latency;
                    ip_label.label = "%d ms".printf (latency);
                } else {
                    ip_label.label = "Timeout";
                }

                var result = yield Tester.check_external_ip (settings.current_mixed_port, settings.connection_info_test_url, settings.test_timeout, cancellable);
                if (check_id != status_check_id || cancellable.is_cancelled ()) return;

                if (active_node != null && runner.running) {
                    if (result.ip != "") {
                        if (latency > 0) {
                            ip_label.label = "%s  •  %d ms".printf (result.ip, latency);
                        } else {
                            ip_label.label = result.ip;
                        }
                        string shown = ip_label.label;
                        string? cc = result.country != "" ? result.country : ip_country.lookup (result.ip);
                        if (cc == null) {
                            cc = yield Tester.lookup_country (settings.current_mixed_port, result.ip, settings.test_timeout, cancellable);
                            if (check_id != status_check_id || cancellable.is_cancelled ()) return;
                        }
                        if (cc != "") ip_country.insert (result.ip, cc);
                        if (ip_label.label == shown) show_ip_country (cc);
                    } else if (latency <= 0) {
                        ip_label.label = "Check failed";
                    }
                } else {
                    ip_label.label = "Not connected";
                }
            } finally {
                if (check_id == status_check_id) {
                    checking_status = false;
                    status_cancellable = null;
                }
            }
        }

        private void revert_toggle () {
            updating_ui = true;
            start_button.active = false;
            updating_ui = false;
            if (status_cancellable != null) {
                status_cancellable.cancel ();
                status_cancellable = null;
            }
            checking_status = false;
            update_active_label ();
        }

        private void on_state_changed (bool running) {
            updating_ui = true;
            start_button.active = running;
            start_button.sensitive = true;

            if (running) {
                build_start_button ("Stop", "media-playback-stop-symbolic");
            } else {
                build_start_button ("Start", "media-playback-start-symbolic");
            }
            start_button.child = start_button_content;

            if (running) {
                if (!app_held) {
                    application.hold ();
                    app_held = true;
                }
                start_button.remove_css_class ("suggested-action");
                start_button.add_css_class ("destructive-action");
                // router is already running: make TUN switch reflect actual router mode
                if (tun_switch.active != runner.tun_mode) {
                    tun_switch.active = runner.tun_mode;
                    settings.tun_enabled = runner.tun_mode; // updating_ui mutes notify::active so save setting manually
                    settings.save ();
                }
                if (active_node == null) {
                    restore_active_node_state ();
                }
                if (active_node != null) {
                    active_node.is_active = true;
                }
                restore_active_selection ();
                update_active_label ();
                ensure_engine_alive.begin ();
                check_connection_status.begin (false);
            } else {
                if (app_held) {
                    application.release ();
                    app_held = false;
                }
                if (status_cancellable != null) {
                    status_cancellable.cancel ();
                    status_cancellable = null;
                }
                checking_status = false;
                start_button.remove_css_class ("destructive-action");
                start_button.add_css_class ("suggested-action");
                update_active_label ();
            }
            if (core_row != null) core_row.sensitive = true;
            updating_ui = false;
        }

        private void on_toggled () {
            if (updating_ui) return;
            if (start_button.active) {
                start_flow.begin ();
            } else {
                start_button.sensitive = false;
                build_start_button ("Stopping…", "content-loading-symbolic");
                start_button.child = start_button_content;
                runner.stop ();
            }
        }
    }
}
