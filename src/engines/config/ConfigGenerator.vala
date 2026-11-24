using Vector.Models;
using Vector.Routing;
using Vector.Services;
namespace Vector.Engines {

    public partial class ConfigGenerator : GLib.Object {

        private const string[] PRIVATE_CIDRS = {
            "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
            "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"
        };

        private static string host_cidr (string addr) {
            return addr + (addr.contains (":") ? "/128" : "/32");
        }

        // parse host, host:port, [ipv6]:port etc.
        private static void split_host_port (string hp, out string host, out int port) {
            host = hp;
            port = 0;
            if (hp.has_prefix ("[")) {
                int end = hp.index_of ("]");
                if (end > 0) {
                    host = hp.substring (1, end - 1);
                    string rest = hp.substring (end + 1);
                    if (rest.has_prefix (":")) port = int.parse (rest.substring (1));
                }
                return;
            }
            int first = hp.index_of (":");
            if (first >= 0 && first == hp.last_index_of (":")) {
                host = hp.substring (0, first);
                port = int.parse (hp.substring (first + 1));
            }
        }

        public static string? domain_rule_set_tag (string item) {
            string s = item.strip ();
            if (s == "") return null;
            if (s.has_prefix ("geosite:")) return "geosite-" + s.substring (8).strip ().down ();
            if (s.has_prefix ("geoip:")) {
                string code = s.substring (6).strip ().down ();
                return code == "private" ? null : "geoip-" + code;
            }
            if (s.has_prefix ("ext:") || s.has_prefix ("ext-ip:")) {
                string code = s.substring (s.index_of (":") + 1).strip ().down ();
                return code.contains ("-") ? code : "geosite-" + code;
            }
            if (s.has_prefix ("full:") || s.has_prefix ("domain:") || s.has_prefix ("keyword:")
                || s.has_prefix ("regexp:") || s.has_prefix ("regex:") || s.contains (".")) {
                return null;
            }
            return "geosite-" + s.down (); // bare word defaults to geosite
        }

        public static string? ip_rule_set_tag (string item) {
            string s = item.strip ();
            if (s == "" || s.down () == "private") return null;
            if (s.has_prefix ("geoip:")) {
                string code = s.substring (6).strip ().down ();
                return code == "private" ? null : "geoip-" + code;
            }
            if (s.has_prefix ("geosite:")) return "geosite-" + s.substring (8).strip ().down ();
            if (s.contains ("/") || GLib.Hostname.is_ip_address (s)) return null;
            return "geoip-" + s.down (); // bare word defaults to geoip
        }

        private static void collect_rule_set_tags (string[] domains, string[] ips, GLib.GenericArray<string> out_tags) {
            foreach (var d in domains) {
                string? t = domain_rule_set_tag (d);
                if (t != null) out_tags.add (t);
            }
            foreach (var ip in ips) {
                string? t = ip_rule_set_tag (ip);
                if (t != null) out_tags.add (t);
            }
        }

        public static string[] rule_set_tags_for (AppSettings s, RoutingPreset? preset) {
            var all = new GLib.GenericArray<string> ();
            collect_rule_set_tags (Util.split_list (s.bypass_domains), Util.split_list (s.bypass_ips), all);
            if (preset != null) {
                for (uint i = 0; i < preset.rules.get_n_items (); i++) {
                    var r = (RoutingRule) preset.rules.get_item (i);
                    if (r.enabled) collect_rule_set_tags (Util.split_list (r.domains), Util.split_list (r.ips), all);
                }
            }
            var seen = new GLib.HashTable<string, bool> (str_hash, str_equal);
            string[] result = {};
            foreach (var t in all) {
                if (seen.contains (t)) continue;
                seen.insert (t, true);
                result += t;
            }
            return result;
        }

        private static string[] to_strv (GLib.GenericArray<string> a) {
            string[] r = {};
            foreach (var x in a) r += x;
            return r;
        }

        // router must NEVER capture proxy cores or we loop into TUN until kernel panics
        // testers use the exact same binaries so skip them too
        public const string[] ENGINE_PROCESS_NAMES = { Cores.SING_BOX, Cores.XRAY, Cores.SING_BOX_LX };

        // sing-box has auto_detect_interface magic, but xray needs sockopt.interface bound explicitly
        // to bypass TUN. Kept off by default so generated configs aren't tied to host ifaces
        public static bool bind_xray_to_default_interface = false;

        private static string xray_bind_interface () {
            return bind_xray_to_default_interface ? Util.default_interface () : "";
        }

        // router config does not depend on selected node:
        // switching nodes only restarts engine, router keeps running
        public static string gen_router (AppSettings s, RoutingPreset? preset, int engine_port, bool tun) {
            return gen_sb_routed (null, s, preset, engine_port, tun);
        }

        public static string? gen_router_for (string router_core, AppSettings s, RoutingPreset? preset,
                                              int engine_port, bool tun) {
            switch (router_core) {
                case "sing-box": return gen_router (s, preset, engine_port, tun);
                default:         return null;
            }
        }

        // dummy router with zero inbounds: keeps the session router process alive with its
        // ambient CAP_NET_ADMIN when TUN is turned off, so toggling it back on doesn't ask for password again
        public static string gen_idle_router () {
            var j = new JsonSink ();
            j.obj ();
            j.obj ("log");
            j.str ("level", "warn");
            j.flag ("timestamp", true);
            j.end_obj ();
            j.arr ("outbounds");
            j.obj ();
            j.str ("type", "direct");
            j.str ("tag", "direct");
            j.end_obj ();
            j.end_arr ();
            j.end_obj ();
            return j.finish ();
        }

        public static string gen_engine_for (string core, Models.Node n, int port, AppSettings s) {
            return Cores.uses_xray_config (core) ? gen_engine_xray (n, port, s) : gen_engine_singbox (n, port, s);
        }

        public static string gen_test_for (string core, Models.Node n, uint16 port) {
            return Cores.uses_xray_config (core) ? gen_test_xray (n, port) : gen_test_singbox (n, port);
        }
    }
}
