using Vector.Services;
namespace Vector.Models {

    // ~/.config/vector/settings.json - props get mapped with '-' to '_' automatically,
    // so just add a GObject prop and it saves/loads without boilerplate bs
    public class AppSettings : GLib.Object {
        public const string PING_TEST_URLS[] = {
            "https://www.google.com/generate_204",
            "https://www.youtube.com/generate_204",
            "https://www.googlevideo.com/generate_204",
            "https://www.gstatic.com/generate_204",
            "https://www.apple.com/library/test/success.html",
            "http://www.msftconnecttest.com/connecttest.txt"
        };

        public const string SPEED_TEST_URLS[] = {
            "https://speed.cloudflare.com/__down?bytes=10000000",
            "https://speed.cloudflare.com/__down?bytes=50000000",
            "https://speed.cloudflare.com/__down?bytes=99999999",
            "https://cachefly.cachefly.net/10mb.test",
            "https://cachefly.cachefly.net/50mb.test",
            "https://cachefly.cachefly.net/100mb.test",
            "https://cachefly.cachefly.net/1mb.test"
        };

        // sing-box dns strategy strings. ipv4_only drops ipv6 dests completely in the router
        public const string[] IP_MODES = { "prefer_ipv4", "prefer_ipv6", "ipv4_only" };

        public string core { get; set; default = "xray"; }
        public int mixed_port { get; set; default = 2080; }
        public bool random_mixed_port { get; set; default = false; }
        public int current_mixed_port { get; set; default = 2080; }
        public int engine_port { get; set; default = 0; } // 0 = ephemeral pick on boot
        public bool tun_enabled { get; set; default = false; }
        public string tun_router_core { get; set; default = "sing-box"; }
        public int sysproxy_mode { get; set; default = 2; } // 0: clear, 1: set, 2: dont touch
        public string active_node_id { get; set; default = ""; }
        public bool run_tunnel_in_background { get; set; default = true; }
        public bool run_app_in_background { get; set; default = true; }

        public bool bypass_lan { get; set; default = true; }
        public string bypass_ips { get; set; default = ""; }
        public string bypass_domains { get; set; default = ""; }
        public string remote_dns { get; set; default = "8.8.8.8"; }
        public string direct_dns { get; set; default = "77.88.8.8"; }
        public string ip_mode { get; set; default = "prefer_ipv4"; }

        public string ping_url { get; set; default = "https://www.google.com/generate_204"; }
        public string speed_url { get; set; default = "https://speed.cloudflare.com/__down?bytes=10000000"; }
        public string connection_info_test_url { get; set; default = ""; }
        public int concurrent_tests { get; set; default = 5; }
        public int test_timeout { get; set; default = 10; }

        public string sub_converter_url { get; set; default = ""; }
        public string geo_files_source { get; set; default = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/{0}.dat"; }
        public string singbox_ruleset_source { get; set; default = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-{0}/{1}.srs"; }
        public string routing_rules_source { get; set; default = "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-custom-routing-list/refs/heads/main/v2rayN/all.json"; }
        public int geo_update_interval { get; set; default = 0; } // hrs, 0 = off
        public int64 geo_last_update { get; set; default = 0; }

        public string last_active_tab { get; set; default = ""; }
        public string sort_column { get; set; default = "default"; }
        public bool sort_asc { get; set; default = true; }
        public bool show_all_tab { get; set; default = true; }
        public bool log_wrap { get; set; default = false; }
        public bool log_show_time { get; set; default = true; }

        // per-proto core overrides (vless -> xray, etc). stored as separate json dict since gobject props suck for dicts
        public GLib.HashTable<string, string> protocol_cores = new GLib.HashTable<string, string> (str_hash, str_equal);

        private bool loaded = false;

        construct {
            this.notify.connect ((pspec) => {
                if (loaded) save ();
            });
        }

        public void load () {
            loaded = false;
            // json-glib parser fails on invalid UTF-8 bytes;
            // make_valid() prevents crashing or clearing settings file on load.
            var parser = new Json.Parser ();
            try {
                string text;
                GLib.FileUtils.get_contents (Paths.settings_json (), out text);
                parser.load_from_data (text.make_valid ());
            } catch (GLib.Error e) {
                loaded = true;
                return;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                loaded = true;
                return;
            }
            var o = root.get_object ();

            foreach (var spec in get_class ().list_properties ()) {
                string key = json_key (spec);
                if (o.has_member (key)) load_property (o, key, spec);
            }
            load_protocol_cores (o);
            load_legacy_keys (o);

            if (sort_column != "name" && sort_column != "ping" && sort_column != "speed") sort_column = "default";
            if (core != "xray" && core != "sing-box") core = "xray";
            if (!(ip_mode in IP_MODES)) ip_mode = "prefer_ipv4";
            loaded = true;
        }

        public void save () {
            var b = new Json.Builder ();
            b.begin_object ();
            foreach (var spec in get_class ().list_properties ()) {
                b.set_member_name (json_key (spec));
                save_property (b, spec);
            }
            b.set_member_name ("protocol_cores");
            b.begin_object ();
            protocol_cores.foreach ((k, v) => {
                b.set_member_name (k);
                b.add_string_value (v);
            });
            b.end_object ();
            b.end_object ();
            Util.save_json (b, Paths.settings_json ());
        }

        private static string json_key (GLib.ParamSpec spec) {
            return spec.name.replace ("-", "_");
        }

        // handle loose json types (e.g. numeric strings or booleans if edited by hand)
        private void load_property (Json.Object o, string key, GLib.ParamSpec spec) {
            var value = GLib.Value (spec.value_type);
            if (spec.value_type == typeof (string)) value.set_string (Util.j_str (o, key));
            else if (spec.value_type == typeof (int)) value.set_int (Util.j_int (o, key));
            else if (spec.value_type == typeof (bool)) value.set_boolean (Util.j_bool (o, key));
            else if (spec.value_type == typeof (int64)) value.set_int64 (int64.parse (Util.j_str (o, key)));
            else return;
            set_property (spec.name, value);
        }

        private void save_property (Json.Builder b, GLib.ParamSpec spec) {
            var value = GLib.Value (spec.value_type);
            get_property (spec.name, ref value);
            if (spec.value_type == typeof (string)) b.add_string_value (value.get_string () ?? "");
            else if (spec.value_type == typeof (int)) b.add_int_value (value.get_int ());
            else if (spec.value_type == typeof (bool)) b.add_boolean_value (value.get_boolean ());
            else if (spec.value_type == typeof (int64)) b.add_int_value (value.get_int64 ());
            else b.add_null_value ();
        }

        private void load_protocol_cores (Json.Object o) {
            if (!o.has_member ("protocol_cores") || o.get_member ("protocol_cores").get_node_type () != Json.NodeType.OBJECT) return;
            var cores = o.get_object_member ("protocol_cores");
            foreach (var key in cores.get_members ()) {
                string core_name = Util.j_str (cores, key);
                if (core_name != "") protocol_cores.insert (key, core_name);
            }
        }

        // legacy migration: old versions used socks_port & single run_in_background flag
        private void load_legacy_keys (Json.Object o) {
            if (!o.has_member ("mixed_port") && o.has_member ("socks_port")) mixed_port = Util.j_int (o, "socks_port");
            if (o.has_member ("run_in_background")) {
                bool background = Util.j_bool (o, "run_in_background");
                if (!o.has_member ("run_tunnel_in_background")) run_tunnel_in_background = background;
                if (!o.has_member ("run_app_in_background")) run_app_in_background = background;
            }
        }
    }
}
