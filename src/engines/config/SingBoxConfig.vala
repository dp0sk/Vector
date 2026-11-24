using Vector.Models;
using Vector.Routing;
using Vector.Services;
namespace Vector.Engines {

    public partial class ConfigGenerator {

        // sing-box requires domain_resolver on named DoH/DoT upstreams (it ignores
        // route.default_domain_resolver for DNS servers, smh).
        // Bootstrap over raw UDP IP so we don't loop back into TUN.
        private const string DNS_BOOTSTRAP_TAG = "dns-bootstrap";
        private const string DNS_BOOTSTRAP_ADDR = "77.88.8.8";

        private static void parse_dns_address (string raw_addr, string default_addr, string default_type,
                                               out string type, out string host, out int port, out string? path) {
            string addr = raw_addr.strip ();
            if (addr == "") addr = default_addr;
            type = default_type;
            host = "";
            port = 0;
            path = null;
            if (addr == "local") {
                type = "local";
                return;
            }
            string rest = addr;
            foreach (var scheme in new string[] { "https", "tls", "tcp", "udp" }) {
                if (addr.has_prefix (scheme + "://")) {
                    type = scheme;
                    rest = addr.substring (scheme.length + 3);
                    break;
                }
            }
            if (type == "https") {
                int slash = rest.index_of ("/");
                path = slash >= 0 ? rest.substring (slash) : "/dns-query";
                if (slash >= 0) rest = rest.substring (0, slash);
            }
            split_host_port (rest, out host, out port);
        }

        private static bool dns_needs_resolver (string raw_addr, string default_addr) {
            string type, host; int port; string? path;
            parse_dns_address (raw_addr, default_addr, "udp", out type, out host, out port, out path);
            return type != "local" && !GLib.Hostname.is_ip_address (host);
        }

        private static void write_sb_dns_server (JsonSink j, string tag, string raw_addr, string detour,
                                                 string default_addr, string default_type, string? resolver = null) {
            string type, host; int port; string? path;
            parse_dns_address (raw_addr, default_addr, default_type, out type, out host, out port, out path);
            j.obj ();
            j.str ("tag", tag);
            if (detour != "" && detour != "direct") {
                j.str ("detour", detour);
            }
            j.str ("type", type);
            if (type != "local") {
                j.str ("server", host);
                if (port > 0) { j.num ("server_port", port); }
                if (path != null) { j.str ("path", path); }
                if (resolver != null) { j.str ("domain_resolver", resolver); }
            }
            j.end_obj ();
        }

        private static bool has_ipv6_address (string addresses) {
            foreach (var a in Util.split_list (addresses)) if (a.contains (":")) return true;
            return false;
        }

        private static void write_sb_dns_bootstrap (JsonSink j) {
            j.obj ();
            j.str ("tag", DNS_BOOTSTRAP_TAG);
            j.str ("type", "udp");
            j.str ("server", DNS_BOOTSTRAP_ADDR);
            j.end_obj ();
        }

        // sing-box 1.11+ moved wireguard to endpoints. AWG keys only work in sing-box-lx fork
        private static void sb_wg_endpoint (JsonSink j, Models.Node n, string tag) {
            j.obj ();
            j.str ("type", "wireguard");
            j.str ("tag", tag);
            string[] local = Util.split_list (n.wg.local_address);
            j.strs ("address", local.length > 0 ? local : new string[] { "10.0.0.2/32" });
            j.str ("private_key", n.wg.private_key);
            if (n.wg.mtu > 0) { j.num ("mtu", n.wg.mtu); }
            j.arr ("peers");
            j.obj ();
            j.str ("address", n.address);
            j.num ("port", n.port);
            j.str ("public_key", n.wg.peer_public_key);
            if (n.wg.preshared_key != "") { j.str ("pre_shared_key", n.wg.preshared_key); }
            string[] allowed = Util.split_list (n.wg.allowed_ips);
            j.strs ("allowed_ips", allowed.length > 0 ? allowed : new string[] { "0.0.0.0/0", "::/0" });
            sb_wg_keepalive (j, n);
            j.end_obj ();
            j.end_arr ();
            foreach (var k in Models.Node.AWG_KEYS) {
                string? v = n.wg.awg.lookup (k.down ());
                if (v != null && v.strip () != "") sb_awg_value (j, k, v.strip ());
            }
            j.end_obj ();
        }

        // AWG json schema: ranges and I1..I5 are strings, ports/packet sizes
        // are ints, and random trailers are booleans.
        private static void sb_awg_value (JsonSink j, string key, string value) {
            string name = Models.Node.awg_json_name (key);
            if (key in Models.Node.AWG_BOOL_KEYS) {
                j.flag (name, value.down () == "true" || value == "1");
                return;
            }
            int64 num = 0;
            bool is_text = key.has_prefix ("I") || key == "HeaderProtectionKey";
            if (!is_text && int64.try_parse (value, out num)) j.num (name, num);
            else j.str (name, value);
        }

        // AWG 3.x supports min-max keepalive jitter; stock sing-box chokes on ranges
        // so strip to lower bound if not awg
        private static void sb_wg_keepalive (JsonSink j, Models.Node n) {
            string value = n.wg.keepalive.strip ();
            if (value.contains ("-") && n.protocol != "awg") value = value.split ("-")[0].strip ();
            int64 seconds = 0;
            if (int64.try_parse (value, out seconds)) {
                if (seconds > 0) j.num ("persistent_keepalive_interval", seconds);
            } else if (value != "") {
                j.str ("persistent_keepalive_interval", value);
            }
        }

        // The node as a sing-box outbound tagged `tag` (all protocols except
        // WireGuard / AmneziaWG, which are endpoints: sb_wg_endpoint).
        private static void sb_outbound (JsonSink j, Models.Node n, string tag) {
            if (n.protocol == "hysteria2") {
                sb_hysteria2_outbound (j, n, tag);
                return;
            }
            if (n.protocol == "tuic") {
                sb_tuic_outbound (j, n, tag);
                return;
            }
            j.obj ();
            j.str ("type", n.protocol);
            j.str ("tag", tag);
            j.str ("server", n.address);
            j.num ("server_port", n.port);
            sb_credentials (j, n);
            if (n.tls) sb_tls (j, n);
            sb_transport (j, n);
            j.end_obj ();
        }

        private static void sb_hysteria2_outbound (JsonSink j, Models.Node n, string tag) {
            j.obj ();
            j.str ("type", "hysteria2");
            j.str ("tag", tag);
            j.str ("server", n.address);
            j.num ("server_port", n.port);
            string password = n.password != "" ? n.password : n.uuid;
            j.str ("password", password);
            j.obj ("tls");
            j.flag ("enabled", true);
            j.str ("server_name", n.sni != "" ? n.sni : n.address);
            j.flag ("insecure", n.allow_insecure);
            string[] alpn = Util.split_list (n.alpn);
            if (alpn.length > 0) {
                j.strs ("alpn", alpn);
            }
            j.end_obj ();
            if (n.obfs != "") {
                j.obj ("obfs");
                j.str ("type", n.obfs);
                j.str ("password", n.obfs_password);
                j.end_obj ();
            }
            j.end_obj ();
        }

        private static void sb_tuic_outbound (JsonSink j, Models.Node n, string tag) {
            j.obj ();
            j.str ("type", "tuic");
            j.str ("tag", tag);
            j.str ("server", n.address);
            j.num ("server_port", n.port);
            j.str ("uuid", n.uuid);
            j.str ("password", n.password);
            j.str ("congestion_control", n.congestion_control != "" ? n.congestion_control : "bbr");
            j.str ("udp_relay_mode", n.udp_relay_mode != "" ? n.udp_relay_mode : "native");
            j.obj ("tls");
            j.flag ("enabled", true);
            j.str ("server_name", n.sni != "" ? n.sni : n.address);
            j.flag ("insecure", n.allow_insecure);
            string[] alpn = Util.split_list (n.alpn);
            if (alpn.length > 0) {
                j.strs ("alpn", alpn);
            } else {
                j.strs ("alpn", new string[] { "h3" });
            }
            j.end_obj ();
            j.end_obj ();
        }

        private static void sb_credentials (JsonSink j, Models.Node n) {
            switch (n.protocol) {
                case "vmess":
                    j.str ("uuid", n.uuid);
                    j.str ("security", "auto");
                    break;
                case "vless":
                    j.str ("uuid", n.uuid);
                    if (n.flow != "") { j.str ("flow", n.flow); }
                    j.str ("packet_encoding", "xudp");
                    break;
                case "shadowsocks":
                    j.str ("method", n.method != "" ? n.method : "chacha20-ietf-poly1305");
                    j.str ("password", n.uuid);
                    break;
                case "socks":
                case "http": // "user:pass", if any
                    var credentials = n.uuid.split (":", 2);
                    if (n.uuid != "" && credentials.length == 2) {
                        j.str ("username", credentials[0]);
                        j.str ("password", credentials[1]);
                    }
                    break;
                default: // trojan
                    j.str ("password", n.uuid);
                    break;
            }
        }

        private static void sb_tls (JsonSink j, Models.Node n) {
            j.obj ("tls");
            j.flag ("enabled", true);
            j.str ("server_name", n.sni != "" ? n.sni : n.address);
            if (n.reality) {
                sb_utls (j, n.fp != "" ? n.fp : "chrome");
                j.obj ("reality");
                j.flag ("enabled", true);
                j.str ("public_key", n.pbk);
                j.str ("short_id", n.sid);
                j.end_obj ();
            } else {
                j.flag ("insecure", n.allow_insecure);
                string[] alpn = Util.split_list (n.alpn);
                if (alpn.length > 0) {
                    j.strs ("alpn", alpn);
                }
                if (n.fp != "") sb_utls (j, n.fp);
            }
            j.end_obj ();
        }

        private static void sb_utls (JsonSink j, string fingerprint) {
            j.obj ("utls");
            j.flag ("enabled", true);
            j.str ("fingerprint", fingerprint);
            j.end_obj ();
        }

        // XHTTP is xray-only, fallback to sing-box http transport if forced to run here
        private static void sb_transport (JsonSink j, Models.Node n) {
            string path = n.ws_path != "" ? n.ws_path : "/";
            switch (n.network) {
                case "ws":
                    sb_path_transport (j, "ws", path, n.ws_host, true);
                    break;
                case "grpc":
                    j.obj ("transport");
                    j.str ("type", "grpc");
                    j.str ("service_name", n.grpc_service);
                    j.end_obj ();
                    break;
                case "httpupgrade":
                    sb_path_transport (j, "httpupgrade", path, n.ws_host, false);
                    break;
                case "http":
                case "xhttp":
                case "splithttp":
                    sb_path_transport (j, "http", path, n.ws_host, true);
                    break;
                default:
                    break;
            }
        }

        private static void sb_path_transport (JsonSink j, string type, string path, string host, bool host_header) {
            j.obj ("transport");
            j.str ("type", type);
            j.str ("path", path);
            if (host != "" && host_header) {
                j.obj ("headers");
                j.str ("Host", host);
                j.end_obj ();
            } else if (host != "") {
                j.str ("host", host);
            }
            j.end_obj ();
        }

        private static void write_sb_rule_fields (JsonSink j, RoutingRule r, GLib.GenericArray<string>? global_rule_sets = null) {
            var combined_rule_set = new GLib.GenericArray<string> ();
            if (r.network != "") {
                j.str ("network", r.network);
            }

            if (r.inbound_tag != "") {
                var in_tags = new GLib.GenericArray<string> ();
                string[] parts = r.inbound_tag.split (",");
                foreach (var part in parts) {
                    string p = part.strip ().down ();
                    if (p == "tun") in_tags.add ("tun-in");
                    else if (p == "socks" || p == "socks2" || p == "socks3" || p == "http" || p == "mixed") in_tags.add ("mixed-in");
                }
                if (in_tags.length > 0) {
                    j.strs ("inbound", to_strv (in_tags));
                }
            }

            if (r.port != "") {
                string[] raw_ports = Util.split_list (r.port);
                var sb_ports = new GLib.GenericArray<int> ();
                var sb_port_ranges = new GLib.GenericArray<string> ();
                foreach (var p in raw_ports) {
                    string p_str = p.strip ();
                    if (p_str.contains ("-")) {
                        sb_port_ranges.add (p_str.replace ("-", ":"));
                    } else if (p_str.contains (":")) {
                        sb_port_ranges.add (p_str);
                    } else {
                        int p_int = int.parse (p_str);
                        if (p_int > 0 && p_int <= 65535) sb_ports.add (p_int);
                        else if (p_str != "") sb_port_ranges.add (p_str);
                    }
                }
                if (sb_ports.length > 0) {
                    j.arr ("port");
                    for (uint k = 0; k < sb_ports.length; k++) j.value_num (sb_ports[k]);
                    j.end_arr ();
                }
                if (sb_port_ranges.length > 0) {
                    j.strs ("port_range", to_strv (sb_port_ranges));
                }
            }

            string[] dom_items = Util.split_list (r.domains);
            if (dom_items.length > 0) {
                var rs = write_sb_domain_matchers (j, dom_items, global_rule_sets);
                for (uint i = 0; i < rs.length; i++) combined_rule_set.add (rs[i]);
            }

            string[] ip_items = Util.split_list (r.ips);
            if (ip_items.length > 0) {
                var rs = write_sb_ip_matchers (j, ip_items, global_rule_sets);
                for (uint i = 0; i < rs.length; i++) combined_rule_set.add (rs[i]);
            }

            string[] proc_items = Util.split_list (r.processes);
            if (proc_items.length > 0) {
                j.strs ("process_name", proc_items);
            }

            string[] proto_items = Util.split_list (r.protocol);
            if (proto_items.length > 0) {
                j.strs ("protocol", proto_items);
            }

            if (combined_rule_set.length > 0) {
                j.strs ("rule_set", to_strv (combined_rule_set));
            }
        }

        private static string get_sb_ruleset_url (string rs, AppSettings s) {
            string cat = rs.has_prefix ("geosite-") ? "geosite" : (rs.has_prefix ("geoip-") ? "geoip" : "geosite");
            string src = s.singbox_ruleset_source.strip ();
            if (src.contains ("{0}") || src.contains ("{1}")) {
                return src.replace ("{0}", cat).replace ("{1}", rs);
            }
            return src;
        }

        private static GLib.GenericArray<string> write_sb_domain_matchers (JsonSink j, string[] dom_items, GLib.GenericArray<string>? global_rule_sets = null) {
            var domain = new GLib.GenericArray<string> ();
            var domain_suffix = new GLib.GenericArray<string> ();
            var domain_keyword = new GLib.GenericArray<string> ();
            var domain_regex = new GLib.GenericArray<string> ();
            var rule_set = new GLib.GenericArray<string> ();

            foreach (var item in dom_items) {
                string s = item.strip ();
                if (s == "") continue;
                string? tag = domain_rule_set_tag (s);
                if (tag != null) {
                    rule_set.add (tag);
                    if (global_rule_sets != null) global_rule_sets.add (tag);
                } else if (s.has_prefix ("geoip:")) {
                    // ignore geoip in domain list, handled in ip matchers
                } else if (s.has_prefix ("full:")) {
                    domain.add (s.substring (5).strip ());
                } else if (s.has_prefix ("domain:")) {
                    domain_suffix.add (s.substring (7).strip ());
                } else if (s.has_prefix ("keyword:")) {
                    domain_keyword.add (s.substring (8).strip ());
                } else if (s.has_prefix ("regexp:")) {
                    domain_regex.add (s.substring (7).strip ());
                } else if (s.has_prefix ("regex:")) {
                    domain_regex.add (s.substring (6).strip ());
                } else if (s.has_prefix (".")) {
                    domain_suffix.add (s.substring (1).strip ());
                } else {
                    domain_suffix.add (s);
                }
            }

            if (domain.length > 0)         { j.strs ("domain", to_strv (domain)); }
            if (domain_suffix.length > 0)  { j.strs ("domain_suffix", to_strv (domain_suffix)); }
            if (domain_keyword.length > 0) { j.strs ("domain_keyword", to_strv (domain_keyword)); }
            if (domain_regex.length > 0)   { j.strs ("domain_regex", to_strv (domain_regex)); }
            return rule_set;
        }

        private static GLib.GenericArray<string> write_sb_ip_matchers (JsonSink j, string[] ip_items, GLib.GenericArray<string>? global_rule_sets = null) {
            bool ip_is_private = false;
            var ip_cidr = new GLib.GenericArray<string> ();
            var rule_set = new GLib.GenericArray<string> ();

            foreach (var item in ip_items) {
                string s = item.strip ();
                if (s == "") continue;
                string? tag = ip_rule_set_tag (s);
                if (tag != null) {
                    rule_set.add (tag);
                    if (global_rule_sets != null) global_rule_sets.add (tag);
                } else if (s.down () == "private" || s.down () == "geoip:private") {
                    ip_is_private = true;
                } else {
                    ip_cidr.add (s.contains ("/") ? s : host_cidr (s));
                }
            }

            if (ip_is_private) {
                j.flag ("ip_is_private", true);
            }
            if (ip_cidr.length > 0) {
                j.strs ("ip_cidr", to_strv (ip_cidr));
            }
            return rule_set;
        }

        public static string gen_singbox (Models.Node n, AppSettings s, RoutingPreset? preset = null) {
            return gen_sb_routed (n, s, preset, 0);
        }

        private static string gen_sb_routed (Models.Node? n, AppSettings s, RoutingPreset? preset, int engine_port, bool tun = false) {
            bool router = engine_port > 0;
            // Never give TUN to standalone export config or it loops itself to death without an engine bypass
            tun = tun && router;
            var rule_sets = referenced_rule_sets (s, preset);
            string dns_strategy = s.ip_mode;

            var j = new JsonSink ();
            j.obj ();
            j.obj ("log");
            j.str ("level", "info");
            j.flag ("timestamp", true);
            j.end_obj ();
            sb_router_dns (j, n, s, preset, dns_strategy, rule_sets);
            sb_router_inbounds (j, s, tun);
            sb_router_outbounds (j, n, router, engine_port);
            sb_router_route (j, n, s, preset, rule_sets, tun);
            j.end_obj ();
            return j.finish ();
        }

        private static GLib.GenericArray<string> referenced_rule_sets (AppSettings s, RoutingPreset? preset) {
            var tags = new GLib.GenericArray<string> ();
            collect_rule_set_tags (Util.split_list (s.bypass_domains), Util.split_list (s.bypass_ips), tags);
            if (preset == null) return tags;
            for (uint i = 0; i < preset.rules.get_n_items (); i++) {
                var r = (RoutingRule) preset.rules.get_item (i);
                if (r.enabled) collect_rule_set_tags (Util.split_list (r.domains), Util.split_list (r.ips), tags);
            }
            return tags;
        }

        private static void sb_domain_condition (JsonSink j, string[] items, GLib.GenericArray<string> rule_sets) {
            var used = write_sb_domain_matchers (j, items, rule_sets);
            if (used.length > 0) {
                j.strs ("rule_set", to_strv (used));
            }
        }

        private static void sb_ip_condition (JsonSink j, string[] items, GLib.GenericArray<string> rule_sets) {
            var used = write_sb_ip_matchers (j, items, rule_sets);
            if (used.length > 0) {
                j.strs ("rule_set", to_strv (used));
            }
        }

        private static void sb_router_dns (JsonSink j, Models.Node? n, AppSettings s, RoutingPreset? preset,
                                           string dns_strategy, GLib.GenericArray<string> rule_sets) {
            j.obj ("dns");
            j.arr ("servers");
            // dns-remote detours through engine, so remote resolver handles names without leaking
            string? direct_resolver = dns_needs_resolver (s.direct_dns, "77.88.8.8") ? DNS_BOOTSTRAP_TAG : null;
            write_sb_dns_server (j, "dns-remote", s.remote_dns, "proxy", "8.8.8.8", "tcp");
            write_sb_dns_server (j, "dns-direct", s.direct_dns, "direct", "77.88.8.8", "udp", direct_resolver);
            if (direct_resolver != null) write_sb_dns_bootstrap (j);
            j.end_arr ();

            j.arr ("rules");

            // server domain -> direct DNS. Skip bare IPs: sing-box 1.14+ crashes on ip_cidr DNS rules
            // unless match_response is set. Engine handles its own DNS in router mode anyway.
            if (n != null && !GLib.Hostname.is_ip_address (n.address)) {
                j.obj ();
                j.strs ("domain_suffix", { n.address });
                j.str ("action", "route");
                j.str ("server", "dns-direct");
                j.end_obj ();
            }

            string[] bypass_domains = Util.split_list (s.bypass_domains);
            if (bypass_domains.length > 0) {
                j.obj ();
                sb_domain_condition (j, bypass_domains, rule_sets);
                j.str ("action", "route");
                j.str ("server", "dns-direct");
                j.end_obj ();
            }

            // drop AAAA queries when IPv6 is disabled so clients don't blackhole
            if (dns_strategy == "prefer_ipv4" || dns_strategy == "ipv4_only") {
                j.obj ();
                j.strs ("query_type", { "AAAA" });
                j.str ("action", "predefined");
                j.str ("rcode", "NOERROR");
                j.end_obj ();
            }

            if (preset != null) {
                for (uint i = 0; i < preset.rules.get_n_items (); i++) {
                    var r = (RoutingRule) preset.rules.get_item (i);
                    if (!r.enabled || r.domains == "") continue;
                    string[] domains = Util.split_list (r.domains);
                    if (domains.length == 0) continue;
                    if (r.outbound_tag == "direct") {
                        j.obj ();
                        sb_domain_condition (j, domains, rule_sets);
                        j.str ("action", "route");
                        j.str ("server", "dns-direct");
                        j.end_obj ();
                    } else if (r.outbound_tag == "block") {
                        j.obj ();
                        sb_domain_condition (j, domains, rule_sets);
                        j.str ("action", "predefined");
                        j.str ("rcode", "NOERROR");
                        j.end_obj ();
                    }
                }
            }
            j.end_arr ();

            j.str ("final", "dns-remote");
            j.str ("strategy", dns_strategy);
            j.end_obj ();
        }

        private static void sb_router_inbounds (JsonSink j, AppSettings s, bool tun) {
            j.arr ("inbounds");
            j.obj ();
            j.str ("type", "mixed");
            j.str ("tag", "mixed-in");
            j.str ("listen", "127.0.0.1");
            j.num ("listen_port", s.current_mixed_port);
            j.end_obj ();
            if (tun) {
                j.obj ();
                j.str ("type", "tun");
                j.str ("tag", "tun-in");
                j.str ("interface_name", "vector0");
                // don't assign IPv6 to TUN unless user explicitly wants IPv6.
                // Otherwise clients connect via IPv6 to an IPv4-only node and fail
                // instead of cleanly falling back to IPv4.
                string[] tun_addresses = { "172.19.0.1/30" };
                if (s.ip_mode == "prefer_ipv6") tun_addresses += "fdfe:dcba:9876::1/126";
                j.strs ("address", tun_addresses);
                j.num ("mtu", 1400);
                j.flag ("auto_route", true);
                j.flag ("strict_route", true);
                // keep dns_mode disabled! resolvectl triggers polkit auth prompts during session router,
                // and if user cancels it leaves router hanging. strict_route + hijack-dns catches port 53 anyway.
                j.str ("dns_mode", "disabled");
                j.str ("stack", "mixed");
                j.end_obj ();
            }
            j.end_arr ();
        }

        private static void sb_router_outbounds (JsonSink j, Models.Node? n, bool router, int engine_port) {
            if (!router && n != null && n.is_wireguard ()) {
                j.arr ("endpoints");
                if (n.wg != null) sb_wg_endpoint (j, n, "proxy");
                j.end_arr ();
            }
            j.arr ("outbounds");
            if (router) {
                j.obj ();
                j.str ("type", "socks");
                j.str ("tag", "proxy");
                j.str ("server", "127.0.0.1");
                j.num ("server_port", engine_port);
                j.end_obj ();
            } else if (!n.is_wireguard ()) {
                sb_outbound (j, n, "proxy");
            }
            j.obj ();
            j.str ("type", "direct");
            j.str ("tag", "direct");
            j.end_obj ();
            j.obj ();
            j.str ("type", "block");
            j.str ("tag", "block");
            j.end_obj ();
            j.end_arr ();
        }

        private static void sb_router_route (JsonSink j, Models.Node? n, AppSettings s, RoutingPreset? preset,
                                             GLib.GenericArray<string> rule_sets, bool tun) {
            j.obj ("route");
            j.str ("default_domain_resolver", "dns-direct");
            if (rule_sets.length > 0) sb_rule_set_declarations (j, s, rule_sets);

            j.arr ("rules");

            if (tun) {
                // rule 0: engine process traffic must go direct or we loop forever
                j.obj ();
                j.strs ("process_name", ENGINE_PROCESS_NAMES);
                j.str ("outbound", "direct");
                j.end_obj ();
            }

            j.obj ();
            j.str ("action", "sniff");
            j.strs ("sniffer", { "http", "tls", "quic", "dns" });
            j.end_obj ();

            if (tun) {
                j.obj ();
                j.str ("protocol", "dns");
                j.str ("action", "hijack-dns");
                j.end_obj ();
                j.obj ();
                j.str ("network", "icmp");
                j.str ("outbound", "direct");
                j.end_obj ();
            }

            // apps like Telegram hardcode IPv6 IPs directly; drop immediately so they don't hang
            if (s.ip_mode == "ipv4_only") {
                j.obj ();
                j.num ("ip_version", 6);
                j.str ("action", "reject");
                j.end_obj ();
            }

            if (n != null) {
                j.obj ();
                if (GLib.Hostname.is_ip_address (n.address)) {
                    j.strs ("ip_cidr", { host_cidr (n.address) });
                } else {
                    j.strs ("domain_suffix", { n.address });
                }
                j.str ("outbound", "direct");
                j.end_obj ();
            }

            if (s.bypass_lan) {
                j.obj ();
                j.flag ("ip_is_private", true);
                j.str ("outbound", "direct");
                j.end_obj ();
            }

            string[] bypass_ips = Util.split_list (s.bypass_ips);
            if (bypass_ips.length > 0) {
                j.obj ();
                sb_ip_condition (j, bypass_ips, rule_sets);
                j.str ("outbound", "direct");
                j.end_obj ();
            }

            string[] bypass_domains = Util.split_list (s.bypass_domains);
            if (bypass_domains.length > 0) {
                j.obj ();
                sb_domain_condition (j, bypass_domains, rule_sets);
                j.str ("outbound", "direct");
                j.end_obj ();
            }

            if (preset != null) {
                for (uint i = 0; i < preset.rules.get_n_items (); i++) {
                    var r = (RoutingRule) preset.rules.get_item (i);
                    if (!r.enabled) continue;
                    j.obj ();
                    j.str ("outbound", r.outbound_tag);
                    write_sb_rule_fields (j, r, rule_sets);
                    j.end_obj ();
                }
            }
            j.end_arr ();

            j.str ("final", "proxy");
            if (tun) {
                j.flag ("auto_detect_interface", true);
            }
            j.end_obj ();
        }

        private static void sb_rule_set_declarations (JsonSink j, AppSettings s, GLib.GenericArray<string> rule_sets) {
            j.arr ("rule_set");
            var declared = new GLib.GenericSet<string> (str_hash, str_equal);
            foreach (var tag in rule_sets) {
                if (declared.contains (tag)) continue;
                declared.add (tag);
                string local_path = GLib.Path.build_filename (Paths.data_dir (), tag + ".srs");
                j.obj ();
                if (GLib.FileUtils.test (local_path, GLib.FileTest.EXISTS)) {
                    j.str ("type", "local");
                    j.str ("format", "binary");
                    j.str ("tag", tag);
                    j.str ("path", local_path);
                } else {
                    j.str ("type", "remote");
                    j.str ("format", "binary");
                    j.str ("tag", tag);
                    j.str ("url", get_sb_ruleset_url (tag, s));
                    j.str ("download_detour", "direct");
                }
                j.end_obj ();
            }
            j.end_arr ();
        }

        public static string gen_test_singbox (Models.Node n, uint16 port) {
            return gen_sb_single (n, port, null);
        }

        // engine MUST resolve server address via direct DNS; host DNS query goes
        // straight into TUN, router loops back to engine -> deadlock!
        public static string gen_engine_singbox (Models.Node n, int port, AppSettings s) {
            return gen_sb_single (n, (uint16) port, s);
        }

        private static string gen_sb_single (Models.Node n, uint16 port, AppSettings? engine) {
            var j = new JsonSink ();
            j.obj ();
            j.obj ("log");
            j.str ("level", engine != null ? "warn" : "error");
            if (engine != null) { j.flag ("timestamp", true); }
            j.end_obj ();
            j.obj ("dns");
            j.arr ("servers");
            if (engine != null) {
                bool by_name = dns_needs_resolver (engine.direct_dns, "77.88.8.8");
                write_sb_dns_server (j, "dns-local", engine.direct_dns, "direct", "77.88.8.8", "udp",
                                     by_name ? DNS_BOOTSTRAP_TAG : null);
                if (by_name) write_sb_dns_bootstrap (j);
            } else {
                j.obj ();
                j.str ("type", "local");
                j.str ("tag", "dns-local");
                j.end_obj ();
            }
            j.end_arr ();
            j.arr ("rules");
            j.end_arr ();
            j.str ("final", "dns-local");
            j.str ("strategy", "prefer_ipv4");
            j.end_obj ();
            j.arr ("inbounds");
            j.obj ();
            j.str ("type", "mixed");
            j.str ("tag", "test-in");
            j.str ("listen", "127.0.0.1");
            j.num ("listen_port", port);
            j.end_obj ();
            j.end_arr ();
            if (n.is_wireguard ()) {
                j.arr ("endpoints");
                if (n.wg != null) sb_wg_endpoint (j, n, "proxy");
                j.end_arr ();
            }
            j.arr ("outbounds");
            if (n.is_auto ()) {
                // ping all endpoints in parallel and use fastest
                int count = n.auto_count ();
                for (int i = 0; i < count; i++) sb_outbound (j, n.host_clone (i), "proxy-%d".printf (i));
                j.obj ();
                j.str ("type", "urltest");
                j.str ("tag", "proxy");
                j.arr ("outbounds");
                for (int i = 0; i < count; i++) j.value_str ("proxy-%d".printf (i));
                j.end_arr ();
                if (engine != null && engine.ping_url.strip () != "") j.str ("url", engine.ping_url.strip ());
                j.str ("interval", "3m");
                j.num ("tolerance", 50);
                j.end_obj ();
            } else if (!n.is_wireguard ()) {
                sb_outbound (j, n, "proxy");
            }
            j.obj ();
            j.str ("type", "direct");
            j.str ("tag", "direct");
            j.end_obj ();
            j.end_arr ();
            j.obj ("route");

            j.arr ("rules");
            // refuse IPv6 immediately if WG peer has no v6 address, avoids log spam
            if (n.is_wireguard () && !has_ipv6_address (n.wg.local_address)) {
                j.obj ();
                j.num ("ip_version", 6);
                j.str ("action", "reject");
                j.end_obj ();
            }
            j.end_arr ();
            // auto_detect_interface is mandatory here. Route rule 0 with process name is NOT enough:
            // initial WG/AWG UDP packets go out before router resolves process name, looping back and bricking tunnel
            j.flag ("auto_detect_interface", true);
            j.str ("default_domain_resolver", "dns-local");
            j.str ("final", "proxy");
            j.end_obj ();
            j.end_obj ();
            return j.finish ();
        }
    }
}
