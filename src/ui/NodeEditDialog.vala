using Vector.Models;
using Vector.Engines;
using Vector.Services;
namespace Vector.Ui {

    public class NodeEditDialog : Adw.Dialog {

        public signal void saved ();

        private Models.Node node;
        private Store store;

        private Adw.EntryRow   name_row;
        private Adw.ComboRow   proto_row;
        private Adw.EntryRow   addr_row;
        private Adw.SpinRow    port_row;
        private Adw.EntryRow   uuid_row;

        private Adw.PreferencesGroup ss_group;
        private Adw.ComboRow         method_row;

        private Adw.PreferencesGroup hy2_group;
        private Adw.EntryRow         hy2_obfs_row;
        private Adw.EntryRow         hy2_obfs_pw_row;

        private Adw.PreferencesGroup tuic_group;
        private Adw.EntryRow         tuic_pw_row;
        private Adw.ComboRow         tuic_cc_row;
        private Adw.ComboRow         tuic_udp_row;

        private Adw.PreferencesGroup transport_group;
        private Adw.ComboRow         network_row;
        private Adw.EntryRow         ws_path_row;
        private Adw.EntryRow         ws_host_row;
        private Adw.EntryRow         grpc_svc_row;

        private Adw.PreferencesGroup tls_group;
        private Adw.SwitchRow        tls_row;
        private Adw.EntryRow         sni_row;
        private Adw.ComboRow         fp_row;
        private Adw.EntryRow         alpn_row;
        private Adw.SwitchRow        insecure_row;

        private Adw.PreferencesGroup vless_group;
        private Adw.ComboRow         flow_row;
        private Adw.SwitchRow        reality_row;
        private Adw.EntryRow         pbk_row;
        private Adw.EntryRow         sid_row;

        private const string[] PROTOCOLS = { "vmess", "vless", "trojan", "shadowsocks", "socks", "http", "hysteria2", "tuic" };
        private const string[] NETWORKS  = { "tcp", "ws", "grpc", "httpupgrade", "xhttp", "http" };
        private const string[] FPS       = { "", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized" };
        private const string[] FLOWS     = { "", "xtls-rprx-vision" };
        private const string[] SS_METHODS = {
            "chacha20-ietf-poly1305", "aes-128-gcm", "aes-256-gcm",
            "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
            "2022-blake3-chacha20-poly1305"
        };
        private const string[] TUIC_CCS = { "bbr", "cubic", "new_reno" };
        private const string[] TUIC_UDP_MODES = { "native", "quic" };

        public NodeEditDialog (Models.Node node, Store store) {
            this.node = node;
            this.store = store;
            title = "Edit Server";
            content_width = 520;
            content_height = 700;

            if (node.is_wireguard ()) build_wg_ui ();
            else if (node.is_xray_json ()) build_json_ui ();
            else build_form_ui ();
        }

        private void set_content (Gtk.Widget content, owned Ui.Callback on_save_clicked) {
            var save_btn = new Gtk.Button.with_label ("Save");
            save_btn.clicked.connect (() => { on_save_clicked (); });
            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (DialogHeader.create ("Edit Server", node.name, save_btn, () => { close (); }));
            toolbar.content = content;
            child = toolbar;
        }

        private void build_form_ui () {
            var page = new Adw.PreferencesPage ();
            page.add (build_general_group ());
            page.add (build_shadowsocks_group ());
            page.add (build_hysteria2_group ());
            page.add (build_tuic_group ());
            page.add (build_transport_group ());
            page.add (build_tls_group ());
            page.add (build_vless_group ());

            proto_row.notify["selected"].connect (update_visibility);
            network_row.notify["selected"].connect (update_transport_rows);
            reality_row.notify["active"].connect (update_reality_rows);
            update_visibility ();

            set_content (page, on_save);
        }

        private Adw.PreferencesGroup build_general_group () {
            name_row = entry_row ("Name", node.name);
            proto_row = combo_row ("Protocol", PROTOCOLS, node.protocol);
            addr_row = entry_row ("Address", node.address);
            port_row = new Adw.SpinRow.with_range (1, 65535, 1);
            port_row.title = "Port";
            port_row.value = node.port;
            uuid_row = entry_row ("UUID / Password", (node.protocol == "hysteria2" && node.uuid == "") ? node.password : node.uuid);
            return group ("General", { name_row, proto_row, addr_row, port_row, uuid_row });
        }

        private Adw.PreferencesGroup build_shadowsocks_group () {
            method_row = combo_row ("Cipher Method", SS_METHODS, node.method);
            ss_group = group ("Shadowsocks", { method_row });
            return ss_group;
        }

        private Adw.PreferencesGroup build_hysteria2_group () {
            hy2_obfs_row = entry_row ("Obfs Type", node.obfs);
            hy2_obfs_pw_row = entry_row ("Obfs Password", node.obfs_password);
            hy2_group = group ("Hysteria 2", { hy2_obfs_row, hy2_obfs_pw_row });
            return hy2_group;
        }

        private Adw.PreferencesGroup build_tuic_group () {
            tuic_pw_row = entry_row ("Password", node.password);
            tuic_cc_row = combo_row ("Congestion Control", TUIC_CCS, node.congestion_control != "" ? node.congestion_control : "bbr");
            tuic_udp_row = combo_row ("UDP Relay Mode", TUIC_UDP_MODES, node.udp_relay_mode != "" ? node.udp_relay_mode : "native");
            tuic_group = group ("TUIC", { tuic_pw_row, tuic_cc_row, tuic_udp_row });
            return tuic_group;
        }

        private Adw.PreferencesGroup build_transport_group () {
            network_row = combo_row ("Network", NETWORKS, node.network == "splithttp" ? "xhttp" : node.network);
            ws_path_row = entry_row ("Path", node.ws_path);
            ws_host_row = entry_row ("Host", node.ws_host);
            grpc_svc_row = entry_row ("gRPC Service Name", node.grpc_service);
            transport_group = group ("Transport", { network_row, ws_path_row, ws_host_row, grpc_svc_row });
            return transport_group;
        }

        private Adw.PreferencesGroup build_tls_group () {
            tls_row = switch_row ("TLS", node.tls);
            sni_row = entry_row ("SNI", node.sni);
            fp_row = combo_row ("Fingerprint (uTLS)", FPS, node.fp);
            alpn_row = entry_row ("ALPN", node.alpn);
            insecure_row = switch_row ("Allow Insecure", node.allow_insecure);
            tls_group = group ("TLS", { tls_row, sni_row, fp_row, alpn_row, insecure_row });
            return tls_group;
        }

        private Adw.PreferencesGroup build_vless_group () {
            flow_row = combo_row ("Flow", FLOWS, node.flow);
            reality_row = switch_row ("Reality", node.reality);
            pbk_row = entry_row ("Reality Public Key", node.pbk);
            sid_row = entry_row ("Reality Short ID", node.sid);
            vless_group = group ("VLESS", { flow_row, reality_row, pbk_row, sid_row });
            return vless_group;
        }

        private static Adw.PreferencesGroup group (string title, Gtk.Widget[] rows) {
            var g = new Adw.PreferencesGroup ();
            g.title = title;
            foreach (var row in rows) g.add (row);
            return g;
        }

        private static Adw.EntryRow entry_row (string title, string text) {
            var row = new Adw.EntryRow ();
            row.title = title;
            row.text = text;
            return row;
        }

        private static Adw.SwitchRow switch_row (string title, bool active) {
            var row = new Adw.SwitchRow ();
            row.title = title;
            row.active = active;
            return row;
        }

        private static Adw.ComboRow combo_row (string title, string[] items, string current) {
            var row = new Adw.ComboRow ();
            row.title = title;
            row.model = Widgets.string_list (items);
            row.selected = index_of (items, current, 0);
            return row;
        }

        // format minified sub configs into readable JSON for the editor
        private static string pretty_json (string text) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                if (parser.get_root () == null) return text;
                var gen = new Json.Generator ();
                gen.root = parser.get_root ();
                gen.pretty = true;
                gen.indent = 4;
                return gen.to_data (null);
            } catch (GLib.Error e) {
                return text;
            }
        }

        private void build_json_ui () {
            name_row = new Adw.EntryRow ();
            name_row.title = "Name";
            name_row.text = node.name;
            var group = new Adw.PreferencesGroup ();
            group.add (name_row);

            conf_view = new Gtk.TextView ();
            conf_view.monospace = true;
            conf_view.wrap_mode = Gtk.WrapMode.NONE;
            conf_view.top_margin = conf_view.bottom_margin = 8;
            conf_view.left_margin = conf_view.right_margin = 8;
            conf_view.buffer.text = pretty_json (node.xray_json);
            var scroll = new Gtk.ScrolledWindow ();
            scroll.child = conf_view;
            scroll.vexpand = true;
            scroll.add_css_class ("card");

            var hint = new Gtk.Label ("Xray JSON config: its outbounds, routing, balancers and observatory are used as-is — the engine only swaps in its own inbound.");
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");

            conf_error = new Gtk.Label ("");
            conf_error.wrap = true;
            conf_error.xalign = 0;
            conf_error.add_css_class ("error");
            conf_error.visible = false;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            box.margin_start = box.margin_end = 12;
            box.margin_top = box.margin_bottom = 12;
            box.append (group);
            box.append (hint);
            box.append (scroll);
            box.append (conf_error);

            set_content (box, on_save_json);
        }

        private void on_save_json () {
            var parsed = Models.Node.from_xray_json (conf_view.buffer.text, node.sub_url);
            if (parsed == null) {
                conf_error.label = "The text is not an Xray config (a JSON object with \"outbounds\").";
                conf_error.visible = true;
                return;
            }
            string name = name_row.text.strip ();
            // preserve list metadata (group, order); overwrite properties from parsed JSON
            string group_name = node.group_name;
            uint orig_index = node.orig_index;
            node.update_from (parsed);
            node.group_name = group_name;
            node.orig_index = orig_index;
            node.name = name != "" ? name : parsed.name;
            store.save_nodes ();
            node.notify_property ("name");
            saved ();
            this.close ();
        }

        private Gtk.TextView? conf_view = null;
        private Gtk.Label? conf_error = null;

        private const string WG_TEMPLATE =
            "[Interface]\nPrivateKey = \nAddress = 10.8.0.2/32\nDNS = 1.1.1.1\n" +
            "Jc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nS2 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n\n" +
            "[Peer]\nPublicKey = \nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = host:51820\nPersistentKeepalive = 25\n";

        private void build_wg_ui () {
            name_row = new Adw.EntryRow ();
            name_row.title = "Name";
            name_row.text = node.name;
            var group = new Adw.PreferencesGroup ();
            group.add (name_row);

            conf_view = new Gtk.TextView ();
            conf_view.monospace = true;
            conf_view.wrap_mode = Gtk.WrapMode.CHAR;
            conf_view.top_margin = conf_view.bottom_margin = 8;
            conf_view.left_margin = conf_view.right_margin = 8;
            conf_view.buffer.text = node.wg.private_key != "" ? node.to_wg_conf () : WG_TEMPLATE;
            var scroll = new Gtk.ScrolledWindow ();
            scroll.child = conf_view;
            scroll.vexpand = true;
            scroll.add_css_class ("card");

            var hint = new Gtk.Label ("WireGuard or AmneziaWG config (awg-quick format). " +
                "Jc…S4, H1…H4 and I1…I5 make it AmneziaWG.");
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");

            conf_error = new Gtk.Label ("");
            conf_error.wrap = true;
            conf_error.xalign = 0;
            conf_error.add_css_class ("error");
            conf_error.visible = false;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            box.margin_start = box.margin_end = 12;
            box.margin_top = box.margin_bottom = 12;
            box.append (group);
            box.append (hint);
            box.append (scroll);
            box.append (conf_error);

            set_content (box, on_save_wg);
        }

        private void on_save_wg () {
            string ignored;
            // handle vpn:// link pasted directly into conf text view
            string text = conf_view.buffer.text.strip ();
            if (text.has_prefix ("vpn://")) text = Models.Node.amnezia_link_to_conf (text) ?? text;
            var parsed = Models.Node.from_wg_conf (text, node.sub_url, out ignored);
            if (parsed == null) {
                conf_error.label = "The config needs PrivateKey, a [Peer] PublicKey and Endpoint = host:port.";
                conf_error.visible = true;
                return;
            }
            string name = name_row.text.strip ();
            // preserve list metadata (group, order); overwrite properties from parsed conf
            string group_name = node.group_name;
            uint orig_index = node.orig_index;
            node.update_from (parsed);
            node.group_name = group_name;
            node.orig_index = orig_index;
            node.name = name != "" ? name : parsed.name;
            store.save_nodes ();
            node.notify_property ("name");
            saved ();
            this.close ();
        }

        private void update_visibility () {
            string proto = PROTOCOLS[proto_row.selected];
            bool is_ss         = proto == "shadowsocks";
            bool is_hy2        = proto == "hysteria2";
            bool is_tuic       = proto == "tuic";
            bool has_transport = proto == "vmess" || proto == "vless" || proto == "trojan";
            bool has_tls       = has_transport || is_hy2 || is_tuic;
            bool is_vless      = proto == "vless";

            ss_group.visible        = is_ss;
            hy2_group.visible       = is_hy2;
            tuic_group.visible      = is_tuic;
            transport_group.visible = has_transport;
            tls_group.visible       = has_tls;
            vless_group.visible     = is_vless;

            if (is_hy2 || is_tuic) {
                tls_row.active = true;
            }

            if (has_transport) update_transport_rows ();
            if (is_vless)      update_reality_rows ();

            if (is_ss || is_hy2) {
                uuid_row.title = "Password";
            } else if (is_tuic) {
                uuid_row.title = "UUID";
            } else {
                uuid_row.title = "UUID / Password";
            }
        }

        private void update_transport_rows () {
            string net = NETWORKS[network_row.selected];
            bool has_path = net != "tcp" && net != "grpc";
            ws_path_row.visible  = has_path;
            ws_host_row.visible  = has_path;
            grpc_svc_row.visible = net == "grpc";
        }

        private void update_reality_rows () {
            bool r = reality_row.active;
            pbk_row.visible = r;
            sid_row.visible = r;
        }

        // Save

        private void on_save () {
            node.name     = name_row.text.strip ();
            node.protocol = PROTOCOLS[proto_row.selected];
            node.address  = addr_row.text.strip ();
            node.port     = (int) port_row.value;
            node.uuid     = uuid_row.text.strip ();

            if (node.protocol == "shadowsocks") {
                node.method = SS_METHODS[method_row.selected];
            }

            if (node.protocol == "hysteria2") {
                node.password      = node.uuid;
                node.obfs          = hy2_obfs_row.text.strip ();
                node.obfs_password = hy2_obfs_pw_row.text.strip ();
            }

            if (node.protocol == "tuic") {
                node.password           = tuic_pw_row.text.strip ();
                node.congestion_control = TUIC_CCS[tuic_cc_row.selected];
                node.udp_relay_mode     = TUIC_UDP_MODES[tuic_udp_row.selected];
            }

            if (transport_group.visible) {
                node.network      = NETWORKS[network_row.selected];
                node.ws_path      = ws_path_row.text.strip ();
                node.ws_host      = ws_host_row.text.strip ();
                node.grpc_service = grpc_svc_row.text.strip ();
            }

            if (tls_group.visible) {
                node.tls            = (node.protocol == "hysteria2" || node.protocol == "tuic") ? true : tls_row.active;
                node.sni            = sni_row.text.strip ();
                node.fp             = FPS[fp_row.selected];
                node.alpn           = alpn_row.text.strip ();
                node.allow_insecure = insecure_row.active;
            }

            if (vless_group.visible) {
                node.flow    = FLOWS[flow_row.selected];
                node.reality = reality_row.active;
                node.pbk     = pbk_row.text.strip ();
                node.sid     = sid_row.text.strip ();
            }

            store.save_nodes ();
            node.notify_property ("name"); // trigger NodeRow refresh
            saved ();
            this.close ();
        }

        private static uint index_of (string[] arr, string val, uint fallback) {
            for (uint i = 0; i < arr.length; i++) {
                if (arr[i] == val) return i;
            }
            return fallback;
        }
    }
}
