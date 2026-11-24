using Vector.Models;
using Vector.Routing;
using Vector.Services;
namespace Vector.Engines {

    public partial class ConfigGenerator {

        // dial_strategy forces xray to resolve server IP using internal DNS
        private static void xr_outbound (JsonSink j, Models.Node n, string tag, string? dial_strategy = null,
                                         string bind_iface = "") {
            j.obj ();
            j.str ("protocol", n.protocol);
            j.str ("tag", tag);
            j.obj ("settings");
            switch (n.protocol) {
                case "trojan":
                case "shadowsocks":
                case "socks":
                case "http":
                    j.member ("servers");
                    xr_server (j, n);
                    break;
                default: // vless, vmess
                    j.member ("vnext");
                    xr_vnext (j, n);
                    break;
            }
            j.end_obj ();
            j.member ("streamSettings");
            xr_stream_settings (j, n, dial_strategy, bind_iface);
            j.end_obj ();
        }

        private static void xr_server (JsonSink j, Models.Node n) {
            j.begin_arr ();
            j.obj ();
            j.str ("address", n.address);
            j.num ("port", n.port);
            switch (n.protocol) {
                case "trojan":
                    j.str ("password", n.uuid);
                    break;
                case "shadowsocks":
                    j.str ("method", n.method != "" ? n.method : "chacha20-ietf-poly1305");
                    j.str ("password", n.uuid);
                    break;
                default: // socks, http: "user:pass", if any
                    var credentials = n.uuid.split (":", 2);
                    if (n.uuid != "" && credentials.length == 2) {
                        j.arr ("users");
                        j.obj ();
                        j.str ("user", credentials[0]);
                        j.str ("pass", credentials[1]);
                        j.end_obj ();
                        j.end_arr ();
                    }
                    break;
            }
            j.end_obj ();
            j.end_arr ();
        }

        private static void xr_vnext (JsonSink j, Models.Node n) {
            j.begin_arr ();
            j.obj ();
            j.str ("address", n.address);
            j.num ("port", n.port);
            j.arr ("users");
            j.obj ();
            j.str ("id", n.uuid);
            if (n.protocol == "vmess") {
                j.str ("security", "auto");
            } else {
                j.str ("encryption", n.encryption != "" ? n.encryption : "none");
                if (n.flow != "") { j.str ("flow", n.flow); }
            }
            j.end_obj ();
            j.end_arr ();
            j.end_obj ();
            j.end_arr ();
        }

        private static void xr_stream_settings (JsonSink j, Models.Node n, string? dial_strategy, string bind_iface) {
            j.obj ();
            j.str ("network", n.network);
            j.str ("security", n.tls ? (n.reality ? "reality" : "tls") : "none");
            if (n.tls && n.reality) xr_reality_settings (j, n);
            else if (n.tls) xr_tls_settings (j, n);
            xr_transport_settings (j, n);
            if (dial_strategy != null || bind_iface != "") {
                j.obj ("sockopt");
                if (dial_strategy != null) j.str ("domainStrategy", dial_strategy);
                if (bind_iface != "") j.str ("interface", bind_iface);
                j.end_obj ();
            }
            j.end_obj ();
        }

        private static void xr_reality_settings (JsonSink j, Models.Node n) {
            j.obj ("realitySettings");
            j.str ("serverName", n.sni != "" ? n.sni : n.address);
            j.str ("fingerprint", n.fp != "" ? n.fp : "chrome");
            j.str ("publicKey", n.pbk);
            j.str ("shortId", n.sid);
            j.str ("spiderX", "");
            j.end_obj ();
        }

        private static void xr_tls_settings (JsonSink j, Models.Node n) {
            j.obj ("tlsSettings");
            j.str ("serverName", n.sni != "" ? n.sni : n.address);
            // DO NOT emit allowInsecure! Xray 26+ flat out refuses configs with allowInsecure: true
            // (wants pinnedPeerCertSha256 instead). So certs are always verified here, unlike sing-box.
            string[] alpn = Util.split_list (n.alpn);
            if (alpn.length > 0) {
                j.strs ("alpn", alpn);
            }
            if (n.fp != "") {
                j.str ("fingerprint", n.fp);
            }
            j.end_obj ();
        }

        private static void xr_transport_settings (JsonSink j, Models.Node n) {
            string path = n.ws_path != "" ? n.ws_path : "/";
            switch (n.network) {
                case "ws":
                    j.obj ("wsSettings");
                    j.str ("path", path);
                    if (n.ws_host != "") {
                        j.obj ("headers");
                        j.str ("Host", n.ws_host);
                        j.end_obj ();
                    }
                    j.end_obj ();
                    break;
                case "grpc":
                    j.obj ("grpcSettings");
                    j.str ("serviceName", n.grpc_service);
                    j.end_obj ();
                    break;
                case "httpupgrade":
                    xr_path_host_settings (j, "httpupgradeSettings", path, n.ws_host);
                    break;
                case "xhttp":
                case "splithttp":
                    xr_path_host_settings (j, "xhttpSettings", path, n.ws_host);
                    break;
                default:
                    break;
            }
        }

        private static void xr_path_host_settings (JsonSink j, string member, string path, string host) {
            j.member (member);
            j.obj ();
            j.str ("path", path);
            if (host != "") {
                j.str ("host", host);
            }
            j.end_obj ();
        }

        // translate to xray syntax: plain strings in xray are stupid substring matches,
        // so map dotted domains to domain: prefix for proper suffix matching
        private static string[] xr_domains (string[] items) {
            string[] r = {};
            foreach (var item in items) {
                string s = item.strip ();
                if (s == "" || s.has_prefix ("geoip:")) continue; // IPs handled in xr_ips
                if (s.has_prefix ("regex:")) r += "regexp:" + s.substring (6);
                else if (s.has_prefix ("geosite:") || s.has_prefix ("domain:") || s.has_prefix ("full:")
                         || s.has_prefix ("keyword:") || s.has_prefix ("regexp:") || s.has_prefix ("ext:")) r += s;
                else if (s.has_prefix (".")) r += "domain:" + s.substring (1);
                else if (s.contains (".")) r += "domain:" + s;
                else r += "geosite:" + s.down ();
            }
            return r;
        }

        // geoip: entries might appear in domain list by accident, catch them here
        private static string[] xr_ips (string[] items, string[] domain_items) {
            string[] r = {};
            foreach (var item in items) {
                string s = item.strip ();
                if (s == "") continue;
                if (s.down () == "private") r += "geoip:private";
                else if (s.has_prefix ("geoip:") || s.has_prefix ("ext-ip:") || s.contains ("/")
                         || GLib.Hostname.is_ip_address (s)) r += s;
                else if (s.has_prefix ("geosite:")) continue;
                else r += "geoip:" + s.down ();
            }
            foreach (var item in domain_items) {
                string s = item.strip ();
                if (s.has_prefix ("geoip:")) r += s;
            }
            return r;
        }

        public static string gen_xray (Models.Node n, AppSettings s, RoutingPreset? preset = null) {
            var j = new JsonSink ();
            j.obj ();

            j.obj ("log");
            j.str ("loglevel", "warning");
            j.end_obj ();

            j.arr ("inbounds");
            j.obj ();
            j.str ("tag", "mixed-in");
            j.str ("listen", "127.0.0.1");
            j.num ("port", s.current_mixed_port);
            j.str ("protocol", "mixed");
            j.obj ("settings");
            j.flag ("udp", true);
            j.end_obj ();
            j.obj ("sniffing");
            j.flag ("enabled", true);
            j.strs ("destOverride", { "http", "tls" });
            j.end_obj ();
            j.end_obj ();

            j.end_arr ();

            j.arr ("outbounds");
            xr_outbound (j, n, "proxy");
            j.obj ();
            j.str ("protocol", "freedom");
            j.str ("tag", "direct");
            j.end_obj ();
            j.obj ();
            j.str ("protocol", "blackhole");
            j.str ("tag", "block");
            j.end_obj ();
            j.end_arr ();

            xr_routing (j, n, s, preset);
            j.end_obj ();
            return j.finish ();
        }

        private static void xr_routing (JsonSink j, Models.Node n, AppSettings s, RoutingPreset? preset) {
            j.obj ("routing");
            j.str ("domainStrategy", preset != null && preset.domain_strategy != "" ? preset.domain_strategy : "AsIs");
            j.arr ("rules");
            xr_bypass_rules (j, n, s);
            if (preset != null) {
                for (uint i = 0; i < preset.rules.get_n_items (); i++) {
                    var rule = (RoutingRule) preset.rules.get_item (i);
                    if (!rule.enabled) continue;
                    if (!xr_preset_rule (j, rule)) break; // nothing after catch-all can match
                }
            }
            j.end_arr ();
            j.end_obj ();
        }

        private static void xr_bypass_rules (JsonSink j, Models.Node n, AppSettings s) {
            if (GLib.Hostname.is_ip_address (n.address)) xr_direct_rule (j, "ip", { host_cidr (n.address) });
            else xr_direct_rule (j, "domain", { "full:" + n.address });
            if (s.bypass_lan) xr_direct_rule (j, "ip", PRIVATE_CIDRS);
            xr_direct_rule (j, "ip", xr_ips (Util.split_list (s.bypass_ips), {}));
            string[] bypass_domains = Util.split_list (s.bypass_domains);
            xr_direct_rule (j, "domain", xr_domains (bypass_domains));
            xr_direct_rule (j, "ip", xr_ips ({}, bypass_domains));
        }

        private static void xr_direct_rule (JsonSink j, string member, string[] items) {
            if (items.length == 0) return;
            j.obj ();
            j.str ("type", "field");
            j.strs (member, items);
            j.str ("outboundTag", "direct");
            j.end_obj ();
        }

        private static bool xr_preset_rule (JsonSink j, RoutingRule r) {
            string[] raw_domains = Util.split_list (r.domains);
            string[] domains = xr_domains (raw_domains);
            string[] ips = xr_ips (Util.split_list (r.ips), raw_domains);
            string[] processes = Util.split_list (r.processes);
            string[] protocols = Util.split_list (r.protocol);
            bool local_inbound = xr_has_local_inbound (r.inbound_tag);
            bool has_matcher = local_inbound || r.network != "" || r.port != "" || domains.length > 0
                               || ips.length > 0 || processes.length > 0 || protocols.length > 0;
            // xray won't match-all without an explicit condition, so force tcp,udp for catch-all
            string network = has_matcher ? r.network : "tcp,udp";

            // xray ANDs rule matchers whereas sing-box ORs them.
            // Split into two separate rules if both domain and IP are specified.
            bool split = domains.length > 0 && ips.length > 0;
            for (int pass = 0; pass < (split ? 2 : 1); pass++) {
                bool with_domains = domains.length > 0 && pass == 0;
                bool with_ips = ips.length > 0 && (!split || pass == 1);

                j.obj ();
                j.str ("type", "field");
                j.str ("outboundTag", r.outbound_tag);
                if (local_inbound) {
                    j.strs ("inboundTag", { "mixed-in" });
                }
                if (network != "") {
                    j.str ("network", network);
                }
                if (r.port != "") {
                    j.str ("port", r.port);
                }
                if (with_domains) {
                    j.strs ("domain", domains);
                }
                if (with_ips) {
                    j.strs ("ip", ips);
                }
                if (processes.length > 0) {
                    j.strs ("process", processes);
                }
                if (protocols.length > 0) {
                    j.strs ("protocol", protocols);
                }
                j.end_obj ();
            }
            return has_matcher;
        }

        private static bool xr_has_local_inbound (string inbound_tags) {
            foreach (var part in inbound_tags.split (",")) {
                switch (part.strip ().down ()) {
                    case "tun": case "socks": case "socks2": case "socks3": case "http": case "mixed":
                        return true;
                    default:
                        break;
                }
            }
            return false;
        }

        public static string gen_test_xray (Models.Node n, uint16 port) {
            return gen_xr_single (n, port, null);
        }

        // engine resolves server address with internal DNS (sockopt.domainStrategy);
        // system DNS would route straight into TUN and hang forever
        public static string gen_engine_xray (Models.Node n, int port, AppSettings s) {
            return gen_xr_single (n, (uint16) port, s);
        }

        // user pasted a whole raw xray json config: keep their outbounds, balancers,
        // observatory and routing intact, just hijack inbounds with our socks port
        private static string gen_xr_embedded (Models.Node n, uint16 port, AppSettings? engine) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (n.xray_json);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return "";
                var o = root.get_object ();

                var in_arr = new Json.Array ();
                var in_obj = new Json.Object ();
                in_obj.set_string_member ("tag", "socks");
                in_obj.set_int_member ("port", port);
                in_obj.set_string_member ("listen", "127.0.0.1");
                in_obj.set_string_member ("protocol", "socks");
                var st = new Json.Object ();
                st.set_boolean_member ("udp", true);
                st.set_string_member ("auth", "noauth");
                in_obj.set_object_member ("settings", st);
                bool has_sniffing = false;
                if (o.has_member ("inbounds") && o.get_member ("inbounds").get_node_type () == Json.NodeType.ARRAY) {
                    foreach (var el in o.get_array_member ("inbounds").get_elements ()) {
                        if (el.get_node_type () == Json.NodeType.OBJECT && el.get_object ().has_member ("sniffing")) {
                            in_obj.set_member ("sniffing", el.get_object ().get_member ("sniffing").copy ());
                            has_sniffing = true;
                            break;
                        }
                    }
                }
                if (!has_sniffing) {
                    var sn = new Json.Object ();
                    sn.set_boolean_member ("enabled", true);
                    var dest = new Json.Array ();
                    dest.add_string_element ("http");
                    dest.add_string_element ("tls");
                    dest.add_string_element ("quic");
                    sn.set_array_member ("destOverride", dest);
                    in_obj.set_object_member ("sniffing", sn);
                }
                in_arr.add_object_element (in_obj);
                var in_node = new Json.Node (Json.NodeType.ARRAY);
                in_node.set_array (in_arr);
                o.set_member ("inbounds", in_node);
                if (o.has_member ("log") && o.get_member ("log").get_node_type () == Json.NodeType.OBJECT) {
                    o.get_object_member ("log").set_string_member ("loglevel", engine != null ? "warning" : "error");
                }

                var gen = new Json.Generator ();
                gen.root = root;
                gen.pretty = false;
                return gen.to_data (null);
            } catch (GLib.Error e) {
                return ""; // broken json blob, caller deals with it
            }
        }

        private static string gen_xr_single (Models.Node n, uint16 port, AppSettings? engine) {
            if (n.xray_json != "") return gen_xr_embedded (n, port, engine);
            var j = new JsonSink ();
            j.obj ();
            j.obj ("log");
            j.str ("loglevel", engine != null ? "warning" : "error");
            if (engine != null) { j.str ("access", "none"); }
            j.end_obj ();
            if (engine != null) {
                string dns_s = engine.direct_dns.strip () != "" ? engine.direct_dns.strip () : "77.88.8.8";
                if (dns_s.has_prefix ("tls://")) dns_s = "tcp://" + dns_s.substring (6); // xray has no DoT
                j.obj ("dns");
                j.strs ("servers", { dns_s });
                // tag as dns-direct so routing punches through; otherwise it loops trying to resolve proxy via proxy
                j.str ("tag", "dns-direct");
                j.end_obj ();
                j.obj ("routing");
                j.arr ("rules");
                j.obj ();
                j.str ("type", "field");
                j.strs ("inboundTag", { "dns-direct" });
                j.str ("outboundTag", "direct");
                j.end_obj ();
                if (n.is_auto ()) {
                    // dns-direct rule MUST come first because xray routing rules are first-match
                    j.obj ();
                    j.str ("type", "field");
                    j.str ("network", "tcp,udp");
                    j.str ("balancerTag", "proxy-bal");
                    j.end_obj ();
                }
                j.end_arr ();
                if (n.is_auto ()) {
                    j.arr ("balancers");
                    j.obj ();
                    j.str ("tag", "proxy-bal");
                    j.strs ("selector", { "proxy-" });
                    j.obj ("strategy");
                    j.str ("type", "leastPing");
                    j.end_obj ();
                    j.end_obj ();
                    j.end_arr ();
                }
                j.end_obj ();
                // observatory MUST be at top level! Inside routing block xray quietly ignores it
                // and then leastPing balancer blows up with "dependencies not resolved", pure pain
                if (n.is_auto ()) {
                    j.obj ("observatory");
                    j.strs ("subjectSelector", { "proxy-" });
                    j.str ("probeUrl", engine.ping_url.strip () != "" ? engine.ping_url.strip () : "https://www.google.com/generate_204");
                    j.str ("probeInterval", "3m");
                    j.end_obj ();
                }
            }
            j.arr ("inbounds");
            j.obj ();
            j.str ("listen", "127.0.0.1");
            j.num ("port", port);
            j.str ("protocol", "socks");
            j.obj ("settings");
            j.flag ("udp", true);
            j.str ("auth", "noauth");
            j.end_obj ();
            j.end_obj ();
            j.end_arr ();
            j.arr ("outbounds");
            string iface = xray_bind_interface ();
            if (n.is_auto ()) {
                // per-host outbounds for balancer; test config just hits the first one
                int count = n.auto_count ();
                for (int i = 0; i < count; i++) {
                    xr_outbound (j, n.host_clone (i), "proxy-%d".printf (i), engine != null ? "UseIPv4" : null, iface);
                }
            } else {
                xr_outbound (j, n, "proxy", engine != null ? "UseIPv4" : null, iface);
            }
            if (engine != null) {
                j.obj ();
                j.str ("protocol", "freedom");
                j.str ("tag", "direct");
                if (iface != "") {
                    j.obj ("streamSettings");
                    j.obj ("sockopt");
                    j.str ("interface", iface);
                    j.end_obj ();
                    j.end_obj ();
                }
                j.end_obj ();
            }
            j.end_arr ();
            j.end_obj ();
            return j.finish ();
        }
    }
}
