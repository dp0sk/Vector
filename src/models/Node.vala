using Vector.Services;
namespace Vector.Models {

    public class Node : GLib.Object {
        public string name { get; set; default = ""; }
        public string protocol = "vmess";
        public string address = "";
        public int port = 0;
        public string uuid = "";
        public string password = "";
        public string encryption = "";      // vless "encryption" ("none"/empty = classic, xray PQ ciphers use weird strings)
        public string method = "";
        public string network = "tcp";
        public bool tls = false;
        public string sni = "";
        public string ws_path = "";
        public string ws_host = "";
        public string grpc_service = "";
        public string flow = "";
        public string fp = "";              // uTLS fp
        public string alpn = "";
        public bool allow_insecure = true;
        public bool reality = false;
        public string pbk = "";
        public string sid = "";
        public string obfs = "";
        public string obfs_password = "";
        public string congestion_control = "";
        public string udp_relay_mode = "";
        public string sub_url = "";
        public string group_name = "";
        public uint orig_index = 0;
        // multi-host balancer node ("host1:port,host2:port"). engine probes with urltest/leastPing
        public string auto_hosts = "";
        // raw Xray JSON config from provider. Some providers pack full balancers
        // or transports that standard links cannot express. Only xray core can run this.
        public string xray_json = "";

        // wireguard/awg peer settings parsed from conf files
        public WgConfig? wg = null;

        // AWG config keys from awg-quick configs. We keep them lowercase internally,
        // and convert to snake_case json keys for sing-box-lx.
        // AmneziaWG 1.x/2.x: Jc..S4 ints, H1..H4 int or "min-max" range, I1..I5 hex strings.
        // AmneziaWG 3.x adds HeaderProtectionKey (base64), bool flags, and range values.
        public const string[] AWG_KEYS = {
            "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4",
            "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5",
            "HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout",
            "RejectAfterTime", "KeepaliveTimeout", "MaxHandshakeAttempts", "RandomTrailers", "DisableCookies"
        };
        public const string[] AWG_BOOL_KEYS = { "RandomTrailers", "DisableCookies" };

        // convert PascalCase keys to snake_case for sing-box-lx json
        public static string awg_json_name (string key) {
            var sb = new GLib.StringBuilder ();
            for (int i = 0; i < key.length; i++) {
                char c = key[i];
                if (c.isupper () && i > 0) sb.append_c ('_');
                sb.append_c (c.tolower ());
            }
            return sb.str;
        }

        private static string? awg_key_for (string key) {
            foreach (var k in AWG_KEYS) if (k.down () == key.down ()) return k;
            return null;
        }

        public bool is_wireguard () {
            return protocol == "wireguard" || protocol == "awg";
        }

        public int latency   { get; set; default = -1; }
        public int speed_kbps { get; set; default = -1; }
        public bool is_active { get; set; default = false; }

        public string get_id () {
            return "%s|%d|%s%s".printf (address, port, is_wireguard () && wg != null ? wg.peer_public_key : uuid,
                is_auto () ? "@" + auto_hosts : (is_xray_json () ? "@cfg" + xray_json.hash ().to_string () : ""));
        }

        public bool is_auto () {
            return auto_hosts.contains (",");
        }

        public bool is_xray_json () {
            return protocol == "xray-json" || xray_json != "";
        }

        public int auto_count () {
            return is_auto () ? auto_hosts.split (",").length : 1;
        }

        // clones this auto-balancer node into an individual single-host outbound
        public Node host_clone (int i) {
            var c = new Node ();
            c.update_from (this);
            string part = is_auto () ? auto_hosts.split (",")[i] : host_port ();
            int colon = part.last_index_of (":");
            c.address = part[0:colon];
            c.port = int.parse (part[colon + 1:part.length]);
            c.auto_hosts = "";
            return c;
        }

        public Node copy () {
            var c = new Node ();
            c.update_from (this);
            return c;
        }

        public void update_from (Node other) {
            this.name = other.name;
            this.protocol = other.protocol;
            this.address = other.address;
            this.port = other.port;
            this.uuid = other.uuid;
            this.password = other.password;
            this.encryption = other.encryption;
            this.method = other.method;
            this.network = other.network;
            this.tls = other.tls;
            this.sni = other.sni;
            this.ws_path = other.ws_path;
            this.ws_host = other.ws_host;
            this.grpc_service = other.grpc_service;
            this.flow = other.flow;
            this.fp = other.fp;
            this.alpn = other.alpn;
            this.allow_insecure = other.allow_insecure;
            this.reality = other.reality;
            this.pbk = other.pbk;
            this.sid = other.sid;
            this.obfs = other.obfs;
            this.obfs_password = other.obfs_password;
            this.congestion_control = other.congestion_control;
            this.udp_relay_mode = other.udp_relay_mode;
            this.sub_url = other.sub_url;
            this.group_name = other.group_name;
            this.auto_hosts = other.auto_hosts;
            this.xray_json = other.xray_json;
            this.orig_index = other.orig_index;
            this.wg = other.wg != null ? other.wg.copy () : null;
        }

        public static Node? from_link (string raw, string sub_url) {
            string link = raw.strip ();
            if (link.has_prefix ("vmess://"))  return from_vmess (link, sub_url);
            if (link.has_prefix ("vless://"))  return from_uri_style (link, "vless", sub_url);
            if (link.has_prefix ("trojan://")) return from_uri_style (link, "trojan", sub_url);
            if (link.has_prefix ("ss://"))     return from_ss (link, sub_url);
            if (link.has_prefix ("socks://") || link.has_prefix ("socks5://"))
                return from_proxy_uri (link, "socks", sub_url);
            if (link.has_prefix ("http://") || link.has_prefix ("https://"))
                return from_proxy_uri (link, "http", sub_url);
            if (link.has_prefix ("hysteria2://") || link.has_prefix ("hy2://"))
                return from_hysteria2 (link, sub_url);
            if (link.has_prefix ("tuic://"))
                return from_tuic (link, sub_url);
            if (link.has_prefix ("vpn://")) {
                string? conf = amnezia_link_to_conf (link);
                string ignored;
                return conf != null ? from_wg_conf (conf, sub_url, out ignored) : null;
            }
            // some subs return base64 encoded full xray json blobs instead of links
            if (!link.contains ("://")) {
                string? decoded = Util.decode_b64 (link);
                if (decoded != null && decoded.strip ().has_prefix ("{") && decoded.contains ("\"outbounds\"")) {
                    return from_xray_json (decoded, sub_url);
                }
            }
            return null;
        }

        // parse raw xray config json. pulls name from "remarks" and extracts the first
        // outbound's info so UI can at least show an IP/port/proto
        public static Node? from_xray_json (string text, string sub_url) {
            string t = text.strip ();
            var n = new Node ();
            n.sub_url = sub_url;
            n.xray_json = t;
            if (!n.parse_xray_json_fields (t)) return null;
            return n;
        }

        public bool parse_xray_json_fields (string text) {
            string t = text.strip ();
            var parser = new Json.Parser ();
            try { parser.load_from_data (t); } catch (GLib.Error e) { return false; }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return false;
            var o = root.get_object ();
            if (!o.has_member ("outbounds")) return false; // not an xray config

            string remarks = Util.j_str (o, "remarks");
            if (remarks != "" && (name == "" || name == "Xray config")) name = remarks;

            var outbounds = o.get_array_member ("outbounds");
            bool found_proxy = false;

            for (uint i = 0; i < outbounds.get_length (); i++) {
                var ob = outbounds.get_object_element (i);
                if (ob == null) continue;
                string proto = Util.j_str (ob, "protocol");
                if (!is_proxy_protocol (proto)) continue;

                if (!found_proxy) {
                    found_proxy = true;
                    this.protocol = proto;

                    if (ob.has_member ("streamSettings")) {
                        var ss = ob.get_object_member ("streamSettings");
                        string net = Util.j_str (ss, "network");
                        if (net != "") this.network = net;
                        string sec = Util.j_str (ss, "security");
                        if (sec == "tls") {
                            this.tls = true;
                            this.reality = false;
                        } else if (sec == "reality") {
                            this.tls = true;
                            this.reality = true;
                        }

                        if (ss.has_member ("realitySettings")) {
                            var rs = ss.get_object_member ("realitySettings");
                            string s = Util.j_str (rs, "serverName");
                            if (s != "") this.sni = s;
                            string p = Util.j_str (rs, "publicKey");
                            if (p != "") this.pbk = p;
                            string id = Util.j_str (rs, "shortId");
                            if (id != "") this.sid = id;
                            string f = Util.j_str (rs, "fingerprint");
                            if (f != "") this.fp = f;
                        }

                        if (ss.has_member ("tlsSettings")) {
                            var ts = ss.get_object_member ("tlsSettings");
                            string s = Util.j_str (ts, "serverName");
                            if (s != "") this.sni = s;
                            string f = Util.j_str (ts, "fingerprint");
                            if (f != "") this.fp = f;
                            if (ts.has_member ("allowInsecure")) {
                                this.allow_insecure = Util.j_bool (ts, "allowInsecure");
                            }
                            if (ts.has_member ("alpn") && ts.get_member ("alpn").get_node_type () == Json.NodeType.ARRAY) {
                                var alpn_arr = ts.get_array_member ("alpn");
                                string[] alpns = {};
                                for (uint ai = 0; ai < alpn_arr.get_length (); ai++) {
                                    alpns += alpn_arr.get_string_element (ai);
                                }
                                this.alpn = string.joinv (",", alpns);
                            }
                        }

                        if (ss.has_member ("wsSettings")) {
                            var ws = ss.get_object_member ("wsSettings");
                            string p = Util.j_str (ws, "path");
                            if (p != "") this.ws_path = p;
                            if (ws.has_member ("headers")) {
                                var h = ws.get_object_member ("headers");
                                string host = Util.j_str (h, "Host");
                                if (host == "") host = Util.j_str (h, "host");
                                if (host != "") this.ws_host = host;
                            }
                        }

                        if (ss.has_member ("grpcSettings")) {
                            var gr = ss.get_object_member ("grpcSettings");
                            string s = Util.j_str (gr, "serviceName");
                            if (s != "") this.grpc_service = s;
                        }

                        if (ss.has_member ("xhttpSettings")) {
                            var xh = ss.get_object_member ("xhttpSettings");
                            string p = Util.j_str (xh, "path");
                            if (p != "") this.ws_path = p;
                            string h = Util.j_str (xh, "host");
                            if (h != "") this.ws_host = h;
                        }

                        if (ss.has_member ("httpupgradeSettings")) {
                            var hu = ss.get_object_member ("httpupgradeSettings");
                            string p = Util.j_str (hu, "path");
                            if (p != "") this.ws_path = p;
                            string h = Util.j_str (hu, "host");
                            if (h != "") this.ws_host = h;
                        }

                        if (ss.has_member ("httpSettings")) {
                            var hs = ss.get_object_member ("httpSettings");
                            string p = Util.j_str (hs, "path");
                            if (p != "") this.ws_path = p;
                            if (hs.has_member ("host")) {
                                var hm = hs.get_member ("host");
                                if (hm.get_node_type () == Json.NodeType.ARRAY && hs.get_array_member ("host").get_length () > 0) {
                                    this.ws_host = hs.get_array_member ("host").get_string_element (0);
                                } else {
                                    this.ws_host = Util.j_str (hs, "host");
                                }
                            }
                        }


                    }

                    if (ob.has_member ("settings")) {
                        var st = ob.get_object_member ("settings");
                        if (proto == "wireguard") {
                            if (st.has_member ("peers") && st.get_member ("peers").get_node_type () == Json.NodeType.ARRAY
                                && st.get_array_member ("peers").get_length () > 0) {
                                split_endpoint (Util.j_str (st.get_array_member ("peers").get_object_element (0), "endpoint"),
                                                out this.address, out this.port);
                            }
                        } else {
                            string list = st.has_member ("vnext") ? "vnext" : (st.has_member ("servers") ? "servers" : "");
                            if (list != "" && st.get_array_member (list).get_length () > 0) {
                                var srv = st.get_array_member (list).get_object_element (0);
                                this.address = Util.j_str (srv, "address");
                                this.port = Util.j_int (srv, "port");
                                if (srv.has_member ("users") && srv.get_array_member ("users").get_length () > 0) {
                                    var u = srv.get_array_member ("users").get_object_element (0);
                                    this.uuid = Util.j_str (u, "id");
                                    if (this.uuid == "") this.uuid = Util.j_str (u, "password");
                                    string f = Util.j_str (u, "flow");
                                    if (f != "") this.flow = f;
                                    string enc = Util.j_str (u, "encryption");
                                    if (enc != "") this.encryption = enc;
                                } else {
                                    this.password = Util.j_str (srv, "password");
                                    this.method = Util.j_str (srv, "method");
                                    if (this.uuid == "") this.uuid = this.password;
                                }
                            }
                        }
                    }
                }
            }

            if (!found_proxy && (this.protocol == "" || this.protocol == "xray-json")) {
                this.protocol = "xray-json";
            }
            if (this.name == "") this.name = this.address != "" ? this.address : "Xray config";
            return found_proxy || remarks != "";
        }

        // filter out internal routing outbounds (freedom, blackhole, dns) that aren't actual proxy nodes
        public static bool is_proxy_protocol (string protocol) {
            return protocol == "vless" || protocol == "vmess" || protocol == "trojan"
                || protocol == "shadowsocks" || protocol == "socks" || protocol == "http"
                || protocol == "wireguard" || protocol == "hysteria2" || protocol == "tuic";
        }

        private static void split_endpoint (string endpoint, out string host, out int port) {
            host = endpoint;
            port = 0;
            int colon = endpoint.last_index_of (":");
            if (colon > 0) {
                host = endpoint[0:colon].replace ("[", "").replace ("]", "");
                port = int.parse (endpoint[colon + 1:endpoint.length]);
            }
        }



        private static Node? from_vmess (string link, string sub_url) {
            string? payload = Util.decode_b64 (link.substring (8));
            if (payload == null) return null;
            var parser = new Json.Parser ();
            try { parser.load_from_data (payload); } catch (GLib.Error e) { return null; }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return null;
            var o = root.get_object ();
            var n = new Node ();
            n.protocol = "vmess";
            n.sub_url = sub_url;
            n.address = Util.j_str (o, "add");
            n.port = Util.j_int (o, "port");
            n.uuid = Util.j_str (o, "id");
            n.name = Util.j_str (o, "ps");
            if (n.name == "") n.name = n.address;
            n.network = Util.j_str (o, "net");
            if (n.network == "") n.network = "tcp";
            n.tls = Util.j_str (o, "tls") == "tls";
            n.sni = Util.j_str (o, "sni");
            n.ws_path = Util.j_str (o, "path");
            n.ws_host = Util.j_str (o, "host");
            n.fp = Util.j_str (o, "fp");
            n.alpn = Util.j_str (o, "alpn");
            if (n.network == "splithttp") n.network = "xhttp";
            if (n.network == "grpc") n.grpc_service = Util.j_str (o, "path");
            if (n.address == "" || n.port <= 0 || n.uuid == "") return null;
            return n;
        }

        private static Node? from_uri_style (string link, string protocol, string sub_url) {
            // GLib.Uri barfs on multi-host balancer syntax ("@h1:443,h2:443"), so we have to
            // rip the host list out by hand first and slap a dummy host in before passing to Uri.parse
            string host_list = "";
            string parse_link = link;
            int scheme_end = link.index_of ("//");
            if (scheme_end > 0) {
                int auth_start = scheme_end + 2;
                int auth_end = auth_start;
                while (auth_end < link.length && link[auth_end] != '/' && link[auth_end] != '?' && link[auth_end] != '#') auth_end++;
                string authority = link[auth_start:auth_end];
                int at = authority.last_index_of ("@");
                string hostpart = at >= 0 ? authority[at + 1:authority.length] : authority;
                if (hostpart.contains (",")) {
                    int default_port = 0;
                    foreach (var e in hostpart.split (",")) {
                        int c = e.index_of (":");
                        if (c > 0) { default_port = int.parse (e[c + 1:e.length]); break; }
                    }
                    host_list = normalize_host_list (hostpart, default_port);
                    if (host_list == "") return null;
                    string first = hostpart.split (",")[0].strip ();
                    if (!first.contains (":")) {
                        foreach (var e in host_list.split (",")) {
                            int c = e.last_index_of (":");
                            if (c > 0) { default_port = int.parse (e[c + 1:e.length]); break; }
                        }
                        first += ":%d".printf (default_port);
                    }
                    string new_auth = (at >= 0 ? authority[0:at + 1] : "") + first;
                    parse_link = link[0:auth_start] + new_auth + link[auth_end:link.length];
                }
            }
            GLib.Uri uri;
            try { uri = GLib.Uri.parse (parse_link, GLib.UriFlags.NONE); }
            catch (GLib.Error e) { return null; }
            var n = new Node ();
            n.protocol = protocol;
            n.sub_url = sub_url;
            n.uuid = uri.get_userinfo () ?? "";
            n.address = uri.get_host () ?? "";
            n.port = uri.get_port ();
            n.name = uri.get_fragment () ?? "";
            if (n.name == "") n.name = n.address;
            n.tls = protocol == "trojan";
            string? q = uri.get_query ();
            if (q != null) {
                try {
                    var params = GLib.Uri.parse_params (q, -1, "&", GLib.UriParamsFlags.NONE);
                    string? v;
                    if ((v = params.lookup ("type")) != null && v != "") n.network = v;
                    if ((v = params.lookup ("security")) != null) {
                        if (v == "tls") n.tls = true;
                        if (v == "reality") { n.tls = true; n.reality = true; }
                    }
                    if ((v = params.lookup ("sni")) != null) n.sni = v;
                    if ((v = params.lookup ("peer")) != null && n.sni == "") n.sni = v;
                    if ((v = params.lookup ("path")) != null) n.ws_path = v;
                    if ((v = params.lookup ("host")) != null) n.ws_host = v;
                    if ((v = params.lookup ("serviceName")) != null) n.grpc_service = v;
                    if ((v = params.lookup ("flow")) != null) n.flow = v;
                    if ((v = params.lookup ("encryption")) != null && v != "none") n.encryption = v;
                    if ((v = params.lookup ("fp")) != null) n.fp = v;
                    if ((v = params.lookup ("alpn")) != null) n.alpn = v;
                    if ((v = params.lookup ("pbk")) != null) n.pbk = v;
                    if ((v = params.lookup ("sid")) != null) n.sid = v;
                    if ((v = params.lookup ("allowInsecure")) != null) n.allow_insecure = (v == "1" || v == "true");
                    if ((v = params.lookup ("insecure")) != null) n.allow_insecure = (v == "1" || v == "true");
                } catch (GLib.Error e) {
                }
            }
            if (n.network == "splithttp") n.network = "xhttp";
            if (n.reality && n.pbk == "") return null; // reality without pbk is totally broken
            if (n.address == "" || n.port <= 0 || n.uuid == "") return null;
            n.auto_hosts = host_list;
            if (n.is_auto () && n.auto_count () < 2) n.auto_hosts = ""; // degenerate auto node with single host
            return n;
        }

        // fills missing ports in multi-host list from whatever port was given first
        private static string normalize_host_list (string hostpart, int default_port) {
            if (default_port <= 0) return "";
            var sb = new GLib.StringBuilder ();
            foreach (var raw in hostpart.split (",")) {
                string e = raw.strip ();
                if (e == "") return "";
                if (!e.contains (":")) e += ":%d".printf (default_port);
                sb.append (e);
                sb.append_c (',');
            }
            sb.truncate (sb.len - 1);
            return sb.str;
        }

        private static Node? from_ss (string link, string sub_url) {
            GLib.Uri uri;
            try { uri = GLib.Uri.parse (link, GLib.UriFlags.NONE); }
            catch (GLib.Error e) { return null; }
            var n = new Node ();
            n.protocol = "shadowsocks";
            n.sub_url = sub_url;
            n.name = uri.get_fragment () ?? "";

            string userinfo = uri.get_userinfo () ?? "";
            // SIP002 ss links base64-encode method:password
            string decoded_userinfo = userinfo;
            if (!userinfo.contains (":")) {
                var d = Util.decode_b64 (userinfo);
                if (d != null) decoded_userinfo = d;
            }

            var parts = decoded_userinfo.split (":", 2);
            if (parts.length == 2) {
                n.method = parts[0];
                n.uuid = parts[1];
            } else {
                n.uuid = decoded_userinfo;
            }

            n.address = uri.get_host () ?? "";
            n.port = uri.get_port ();
            if (n.name == "") n.name = n.address;
            if (n.address == "" || n.port <= 0 || n.uuid == "") return null;
            return n;
        }

        // parse socks:// and http(s):// links. v2rayN loves base64'ing userinfo in socks links.
        // reject http links with paths/queries so we don't accidentally treat sub urls as nodes
        private static Node? from_proxy_uri (string link, string protocol, string sub_url) {
            GLib.Uri uri;
            try { uri = GLib.Uri.parse (link, GLib.UriFlags.NONE); }
            catch (GLib.Error e) { return null; }
            string path = uri.get_path () ?? "";
            if (protocol == "http" && ((path != "" && path != "/") || uri.get_query () != null)) return null;
            var n = new Node ();
            n.protocol = protocol;
            n.sub_url = sub_url;
            n.address = uri.get_host () ?? "";
            n.port = uri.get_port ();
            n.name = uri.get_fragment () ?? "";
            if (n.name == "") n.name = n.address;
            n.tls = uri.get_scheme () == "https";
            if (n.tls) n.sni = n.address;
            string userinfo = uri.get_userinfo () ?? "";
            if (userinfo != "" && !userinfo.contains (":")) {
                var d = Util.decode_b64 (userinfo);
                if (d != null && d.contains (":")) userinfo = d;
            }
            n.uuid = userinfo;
            if (n.address == "" || n.port <= 0) return null;
            return n;
        }

        private static Node? from_hysteria2 (string link, string sub_url) {
            GLib.Uri uri;
            try { uri = GLib.Uri.parse (link, GLib.UriFlags.NONE); }
            catch (GLib.Error e) { return null; }
            var n = new Node ();
            n.protocol = "hysteria2";
            n.sub_url = sub_url;
            string userinfo = uri.get_userinfo () ?? "";
            if (userinfo.contains (":")) {
                n.password = userinfo.split (":", 2)[1];
            } else {
                n.password = userinfo;
            }
            n.uuid = n.password;
            n.address = uri.get_host () ?? "";
            n.port = uri.get_port ();
            n.name = uri.get_fragment () ?? "";
            if (n.name == "") n.name = n.address;
            n.tls = true;
            n.allow_insecure = false;
            n.network = "udp";
            string? q = uri.get_query ();
            if (q != null) {
                try {
                    var params = GLib.Uri.parse_params (q, -1, "&", GLib.UriParamsFlags.NONE);
                    string? v;
                    if ((v = params.lookup ("sni")) != null && v != "") n.sni = v;
                    if ((v = params.lookup ("peer")) != null && n.sni == "") n.sni = v;
                    if ((v = params.lookup ("alpn")) != null && v != "") n.alpn = v;
                    if ((v = params.lookup ("insecure")) != null) n.allow_insecure = (v == "1" || v == "true");
                    if ((v = params.lookup ("allowInsecure")) != null) n.allow_insecure = (v == "1" || v == "true");
                    if ((v = params.lookup ("allow_insecure")) != null) n.allow_insecure = (v == "1" || v == "true");
                    if ((v = params.lookup ("obfs")) != null && v != "") n.obfs = v;
                    if ((v = params.lookup ("obfs-type")) != null && n.obfs == "") n.obfs = v;
                    if ((v = params.lookup ("obfs-password")) != null && v != "") n.obfs_password = v;
                    if ((v = params.lookup ("obfs_password")) != null && n.obfs_password == "") n.obfs_password = v;
                } catch (GLib.Error e) {}
            }
            if (n.address == "" || n.port <= 0) return null;
            return n;
        }

        private static Node? from_tuic (string link, string sub_url) {
            GLib.Uri uri;
            try { uri = GLib.Uri.parse (link, GLib.UriFlags.NONE); }
            catch (GLib.Error e) { return null; }
            var n = new Node ();
            n.protocol = "tuic";
            n.sub_url = sub_url;
            string userinfo = uri.get_userinfo () ?? "";
            if (userinfo.contains (":")) {
                var parts = userinfo.split (":", 2);
                n.uuid = parts[0];
                n.password = parts[1];
            } else {
                n.uuid = userinfo;
            }
            n.address = uri.get_host () ?? "";
            n.port = uri.get_port ();
            n.name = uri.get_fragment () ?? "";
            if (n.name == "") n.name = n.address;
            n.tls = true;
            n.allow_insecure = false;
            n.network = "udp";
            string? q = uri.get_query ();
            if (q != null) {
                try {
                    var params = GLib.Uri.parse_params (q, -1, "&", GLib.UriParamsFlags.NONE);
                    string? v;
                    if ((v = params.lookup ("congestion_control")) != null && v != "") n.congestion_control = v;
                    if ((v = params.lookup ("congestion-control")) != null && n.congestion_control == "") n.congestion_control = v;
                    if ((v = params.lookup ("udp_relay_mode")) != null && v != "") n.udp_relay_mode = v;
                    if ((v = params.lookup ("udp-relay-mode")) != null && n.udp_relay_mode == "") n.udp_relay_mode = v;
                    if ((v = params.lookup ("udp_relay")) != null && n.udp_relay_mode == "") n.udp_relay_mode = v;
                    if ((v = params.lookup ("sni")) != null && v != "") n.sni = v;
                    if ((v = params.lookup ("peer")) != null && n.sni == "") n.sni = v;
                    if ((v = params.lookup ("alpn")) != null && v != "") n.alpn = v;
                    if ((v = params.lookup ("allow_insecure")) != null) n.allow_insecure = (v == "1" || v == "true");
                    if ((v = params.lookup ("allowInsecure")) != null) n.allow_insecure = (v == "1" || v == "true");
                    if ((v = params.lookup ("insecure")) != null) n.allow_insecure = (v == "1" || v == "true");
                } catch (GLib.Error e) {}
            }
            if (n.address == "" || n.port <= 0 || (n.uuid == "" && n.password == "")) return null;
            return n;
        }

        // Share links: export

        // Inverse of from_link (). Returns null for unsupported protocols.
        // Converts Xray JSON configs to standard plaintext links (vless://, etc.)
        // when possible, or null if the full JSON config cannot be represented.
        public string? to_link () {
            if (xray_json != "") {
                return to_plaintext_link ();
            }
            switch (protocol) {
                case "wireguard":
                case "awg":         return to_wg_conf ();
                case "xray-json":   return to_plaintext_link ();
                case "vless":
                case "trojan":      return uri_style_link ();
                case "vmess":       return vmess_link ();
                case "shadowsocks": return ss_link ();
                case "socks":
                case "http":        return proxy_link ();
                case "hysteria2":   return hysteria2_link ();
                case "tuic":        return tuic_link ();
                default:            return null;
            }
        }

        public string? to_plaintext_link () {
            if (address == "" || port <= 0) return null;
            switch (protocol) {
                case "vless":
                    if (uuid == "") return null;
                    return uri_style_link ();
                case "trojan":
                    if (uuid == "" && password == "") return null;
                    return uri_style_link ();
                case "vmess":
                    if (uuid == "") return null;
                    return vmess_link ();
                case "shadowsocks":
                    if (uuid == "" && password == "") return null;
                    return ss_link ();
                case "socks":
                case "http":
                    return proxy_link ();
                case "hysteria2":
                    if (uuid == "" && password == "") return null;
                    return hysteria2_link ();
                case "tuic":
                    if (uuid == "" && password == "") return null;
                    return tuic_link ();
                case "wireguard":
                case "awg":
                    return to_wg_conf ();
                default:
                    return null;
            }
        }

        private string uri_style_link () {
            var q = new GLib.StringBuilder ();
            add_param (q, "type",        network != "" ? network : "tcp");
            if (protocol == "vless") add_param (q, "encryption", encryption != "" ? encryption : "none");
            add_param (q, "security",    reality ? "reality" : (tls ? "tls" : "none"));
            add_param (q, "sni",         sni);
            add_param (q, "fp",          fp);
            add_param (q, "alpn",        alpn);
            add_param (q, "path",        ws_path);
            add_param (q, "host",        ws_host);
            add_param (q, "serviceName", grpc_service);
            add_param (q, "flow",        flow);
            add_param (q, "pbk",         pbk);
            add_param (q, "sid",         sid);
            if (tls && !reality && allow_insecure) add_param (q, "allowInsecure", "1");
            string cred = protocol == "trojan" ? (password != "" ? password : uuid) : uuid;
            return "%s://%s@%s%s%s".printf (protocol,
                GLib.Uri.escape_string (cred, null, false), hosts_field (), q.str, fragment ());
        }

        private string vmess_link () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("v");    b.add_string_value ("2");
            b.set_member_name ("ps");   b.add_string_value (name);
            b.set_member_name ("add");  b.add_string_value (address);
            b.set_member_name ("port"); b.add_string_value (port.to_string ());
            b.set_member_name ("id");   b.add_string_value (uuid);
            b.set_member_name ("aid");  b.add_string_value ("0");
            b.set_member_name ("scy");  b.add_string_value ("auto");
            b.set_member_name ("net");  b.add_string_value (network != "" ? network : "tcp");
            b.set_member_name ("type"); b.add_string_value ("none");
            b.set_member_name ("host"); b.add_string_value (ws_host);
            b.set_member_name ("path"); b.add_string_value (network == "grpc" ? grpc_service : ws_path);
            b.set_member_name ("tls");  b.add_string_value (tls ? "tls" : "");
            b.set_member_name ("sni");  b.add_string_value (sni);
            b.set_member_name ("alpn"); b.add_string_value (alpn);
            b.set_member_name ("fp");   b.add_string_value (fp);
            b.end_object ();
            var gen = new Json.Generator ();
            gen.root = b.get_root ();
            return "vmess://" + GLib.Base64.encode (gen.to_data (null).data);
        }

        private string ss_link () {
            string m = method != "" ? method : "chacha20-ietf-poly1305";
            return "ss://%s@%s%s".printf (b64url (m + ":" + uuid), host_port (), fragment ());
        }

        private string proxy_link () {
            string scheme = protocol == "socks" ? "socks" : (tls ? "https" : "http");
            string auth = "";
            if (uuid != "") {
                var p = uuid.split (":", 2);
                auth = GLib.Uri.escape_string (p[0], null, false);
                if (p.length == 2) auth += ":" + GLib.Uri.escape_string (p[1], null, false);
                auth += "@";
            }
            return "%s://%s%s%s".printf (scheme, auth, host_port (), fragment ());
        }

        private string hysteria2_link () {
            var q = new GLib.StringBuilder ();
            add_param (q, "sni", sni);
            add_param (q, "alpn", alpn);
            if (allow_insecure) add_param (q, "insecure", "1");
            add_param (q, "obfs", obfs);
            add_param (q, "obfs-password", obfs_password);
            string auth = password != "" ? password : uuid;
            string userinfo = auth != "" ? GLib.Uri.escape_string (auth, null, false) + "@" : "";
            return "hysteria2://%s%s%s%s".printf (userinfo, hosts_field (), q.str, fragment ());
        }

        private string tuic_link () {
            var q = new GLib.StringBuilder ();
            add_param (q, "congestion_control", congestion_control);
            add_param (q, "udp_relay_mode", udp_relay_mode);
            add_param (q, "sni", sni);
            add_param (q, "alpn", alpn);
            if (allow_insecure) add_param (q, "allow_insecure", "1");
            string auth = "";
            if (uuid != "" && password != "") {
                auth = "%s:%s@".printf (GLib.Uri.escape_string (uuid, null, false),
                                        GLib.Uri.escape_string (password, null, false));
            } else if (uuid != "") {
                auth = "%s@".printf (GLib.Uri.escape_string (uuid, null, false));
            } else if (password != "") {
                auth = ":%s@".printf (GLib.Uri.escape_string (password, null, false));
            }
            return "tuic://%s%s%s%s".printf (auth, hosts_field (), q.str, fragment ());
        }

        private static void add_param (GLib.StringBuilder q, string k, string v) {
            if (v == "") return;
            q.append_c (q.len > 0 ? '&' : '?');
            q.append (GLib.Uri.escape_string (k, null, false));
            q.append_c ('=');
            q.append (GLib.Uri.escape_string (v, null, false));
        }

        private string hosts_field () {
            return is_auto () ? auto_hosts : host_port ();
        }

        private string host_port () {
            string h = address.contains (":") && !address.has_prefix ("[") ? "[%s]".printf (address) : address;
            return "%s:%d".printf (h, port);
        }

        private string fragment () {
            return "#" + GLib.Uri.escape_string (name, null, false);
        }

        private static string b64url (string s) {
            return GLib.Base64.encode (s.data).replace ("+", "-").replace ("/", "_").replace ("=", "");
        }

        public static bool looks_like_wg_conf (string text) {
            string t = text.down ();
            return t.contains ("[interface]") && t.contains ("[peer]");
        }

        private class WgPeer {
            public string public_key = "";
            public string preshared_key = "";
            public string allowed_ips = "";
            public string keepalive = "";
            public string address = "";
            public int port = 0;
            public string comment = "";
        }

        // parses wg-quick/awg-quick ini conf. creates one node per [Peer] section.
        // logs any weird unknown keys into `ignored`
        public static GLib.GenericArray<Node> from_wg_conf_all (string text, string sub_url, out string ignored) {
            ignored = "";
            var result = new GLib.GenericArray<Node> ();
            if (!looks_like_wg_conf (text)) return result;

            string iface_private_key = "";
            string iface_address = "";
            string iface_dns = "";
            int iface_mtu = 0;
            var iface_awg = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
            string global_comment_name = "";
            var skipped = new GLib.GenericArray<string> ();

            var peers = new GLib.GenericArray<WgPeer> ();
            WgPeer? current_peer = null;
            string pending_peer_comment = "";
            bool pending_is_explicit = false;
            string section = "";

            foreach (var raw in text.split ("\n")) {
                string line = raw.strip ();
                if (line == "") continue;
                if (line.has_prefix ("#") || line.has_prefix (";")) {
                    string c = line.substring (1).strip ();
                    if (c == "") continue;
                    bool iface_has_data = iface_private_key != "" || iface_address != "";
                    bool peer_has_data = current_peer != null && (current_peer.public_key != "" || current_peer.address != "");
                    if (c.down ().has_prefix ("name") && c.contains ("=")) {
                        string val = c.substring (c.index_of ("=") + 1).strip ();
                        if (section == "interface" && !iface_has_data) {
                            global_comment_name = val;
                        } else if (section == "peer" && current_peer != null && !peer_has_data) {
                            current_peer.comment = val;
                        } else if (section == "") {
                            global_comment_name = val;
                        } else {
                            pending_peer_comment = val;
                            pending_is_explicit = true;
                        }
                    } else if (!c.contains ("=") && !c.has_prefix ("[")) {
                        if (section == "peer" && current_peer != null && !peer_has_data) {
                            if (current_peer.comment == "") current_peer.comment = c;
                        } else if (iface_has_data || peer_has_data) {
                            if (!pending_is_explicit) pending_peer_comment = c;
                        }
                    }
                    continue;
                }
                if (line.has_prefix ("[")) {
                    string s = line.down ().replace ("[", "").replace ("]", "").strip ();
                    if (s == "interface") {
                        section = "interface";
                    } else if (s == "peer") {
                        section = "peer";
                        current_peer = new WgPeer ();
                        if (pending_peer_comment != "") {
                            current_peer.comment = pending_peer_comment;
                        }
                        pending_peer_comment = "";
                        pending_is_explicit = false;
                        peers.add (current_peer);
                    } else {
                        section = s;
                    }
                    continue;
                }
                int eq = line.index_of ("=");
                if (eq <= 0) continue;
                string key = line.substring (0, eq).strip ().down ();
                string val = line.substring (eq + 1).strip ();
                if (section == "interface") {
                    switch (key) {
                        case "privatekey": iface_private_key = val; break;
                        case "address":    iface_address = val; break;
                        case "dns":        iface_dns = val; break;
                        case "mtu":        iface_mtu = int.parse (val); break;
                        default:
                            if (awg_key_for (key) != null) iface_awg.insert (key, val);
                            else if (key != "listenport") skipped.add (key);
                            break;
                    }
                } else if (section == "peer" && current_peer != null) {
                    switch (key) {
                        case "publickey":           current_peer.public_key = val; break;
                        case "presharedkey":        current_peer.preshared_key = val; break;
                        case "allowedips":          current_peer.allowed_ips = val; break;
                        case "persistentkeepalive": current_peer.keepalive = val; break;
                        case "endpoint": {
                            int colon = val.last_index_of (":");
                            if (colon > 0) {
                                current_peer.address = val.substring (0, colon).replace ("[", "").replace ("]", "");
                                current_peer.port = int.parse (val.substring (colon + 1));
                            }
                            break;
                        }
                        default:
                            skipped.add (key);
                            break;
                    }
                }
            }

            ignored = string.joinv (", ", skipped.data);
            if (iface_private_key == "") return result;

            var valid_peers = new GLib.GenericArray<WgPeer> ();
            for (int i = 0; i < peers.length; i++) {
                var p = peers[i];
                if (p.public_key != "" && p.address != "" && p.port > 0) {
                    valid_peers.add (p);
                }
            }

            for (int i = 0; i < valid_peers.length; i++) {
                var p = valid_peers[i];
                var n = new Node ();
                n.wg = new WgConfig ();
                n.sub_url = sub_url;
                n.wg.private_key = iface_private_key;
                n.wg.local_address = iface_address;
                n.wg.dns = iface_dns;
                n.wg.mtu = iface_mtu;
                foreach (var k in AWG_KEYS) {
                    string? v = iface_awg.lookup (k.down ());
                    if (v != null) n.wg.awg.insert (k.down (), v);
                }
                n.wg.peer_public_key = p.public_key;
                n.wg.preshared_key = p.preshared_key;
                n.wg.allowed_ips = p.allowed_ips;
                n.wg.keepalive = p.keepalive;
                n.address = p.address;
                n.port = p.port;
                n.protocol = n.wg.awg.size () > 0 ? "awg" : "wireguard";
                n.network = "udp";

                string proto_label = n.protocol == "awg" ? "AmneziaWG" : "WireGuard";
                if (p.comment != "") {
                    n.name = p.comment;
                } else if (global_comment_name != "") {
                    n.name = (valid_peers.length > 1)
                        ? "%s %d".printf (global_comment_name, i + 1)
                        : global_comment_name;
                } else {
                    string default_name = "%s %s".printf (proto_label, n.address);
                    n.name = (valid_peers.length > 1)
                        ? "%s %d".printf (default_name, i + 1)
                        : default_name;
                }

                result.add (n);
            }

            return result;
        }

        // grabs first peer from conf. skips linux-only stuff like PostUp/Table/etc
        public static Node? from_wg_conf (string text, string sub_url, out string ignored) {
            var all = from_wg_conf_all (text, sub_url, out ignored);
            return all.length > 0 ? all[0] : null;
        }

        // Amnezia vpn:// links: base64url-encoded JSON blob, compressed with Qt's cursed qCompress
        // (4-byte big-endian uncompressed size header followed by zlib stream).
        // Grabs the wireguard/awg container config out of "last_config".
        public static string? amnezia_link_to_conf (string link) {
            var root = amnezia_link_json (link.strip ().substring ("vpn://".length));
            if (root == null) return null;

            string name = Util.j_str (root, "description");
            string dns1 = Util.j_str (root, "dns1");
            string dns2 = Util.j_str (root, "dns2");
            foreach (var container in amnezia_containers (root)) {
                foreach (var member in container.get_members ()) {
                    var node = container.get_member (member);
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var proto = node.get_object ();
                    var last = parse_object (Util.j_str (proto, "last_config"));
                    if (last == null) continue;

                    string conf = Util.j_str (last, "config");
                    if (conf == "") conf = amnezia_conf_from_fields (last, proto, root);
                    conf = conf.replace ("$PRIMARY_DNS", dns1 != "" ? dns1 : "1.1.1.1")
                               .replace ("$SECONDARY_DNS", dns2 != "" ? dns2 : "1.0.0.1");
                    if (!looks_like_wg_conf (conf)) continue;
                    return name != "" ? "# Name = %s\n%s".printf (name, conf) : conf;
                }
            }
            return null;
        }

        // Amnezia Premium API key links: requires auth handshake with amnezia servers, can't parse standalone
        public static bool is_amnezia_api_link (string link) {
            var root = amnezia_link_json (link.strip ().substring ("vpn://".length));
            return root != null && root.has_member ("api_config");
        }

        private static Json.Object? amnezia_link_json (string payload) {
            var data = Util.decode_b64_bytes (payload);
            if (data == null) return null;
            // old links had raw JSON, new ones pack qCompress zlib payload
            if (data[0] != '{') {
                if (data.length <= 4) return null;
                data = Util.zlib_inflate (data[4:data.length]);
                if (data == null) return null;
            }
            return parse_object (Util.bytes_to_string (new GLib.Bytes (data)).make_valid ());
        }

        private static GLib.List<Json.Object> amnezia_containers (Json.Object root) {
            var list = new GLib.List<Json.Object> ();
            if (!root.has_member ("containers") || root.get_member ("containers").get_node_type () != Json.NodeType.ARRAY) return list;
            string preferred = Util.j_str (root, "defaultContainer");
            foreach (var node in root.get_array_member ("containers").get_elements ()) {
                if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                var c = node.get_object ();
                if (Util.j_str (c, "container") == preferred) list.prepend (c);
                else list.append (c);
            }
            return list;
        }

        // some amnezia configs don't give you the raw .conf string in last_config,
        // so we gotta piece together [Interface] and [Peer] by hand from loose json fields
        private static string amnezia_conf_from_fields (Json.Object last, Json.Object proto, Json.Object root) {
            string key = Util.j_str (last, "client_priv_key");
            string peer = Util.j_str (last, "server_pub_key");
            if (key == "" || peer == "") return "";
            string address = Util.j_str (last, "client_ip");
            if (address != "" && !address.contains ("/")) address += "/32";
            string host = first_nonempty (Util.j_str (last, "hostName"), Util.j_str (root, "hostName"));
            string port = first_nonempty (Util.j_str (last, "port"), Util.j_str (proto, "port"));

            var sb = new GLib.StringBuilder ("[Interface]\n");
            sb.append_printf ("PrivateKey = %s\n", key);
            if (address != "") sb.append_printf ("Address = %s\n", address);
            sb.append ("DNS = $PRIMARY_DNS, $SECONDARY_DNS\n");
            string mtu = Util.j_str (last, "mtu");
            if (mtu != "") sb.append_printf ("MTU = %s\n", mtu);
            foreach (var k in AWG_KEYS) {
                string v = first_nonempty (Util.j_str (last, k), Util.j_str (proto, k));
                if (v != "") sb.append_printf ("%s = %s\n", k, v);
            }
            sb.append ("\n[Peer]\n");
            sb.append_printf ("PublicKey = %s\n", peer);
            string psk = Util.j_str (last, "psk_key");
            if (psk != "") sb.append_printf ("PresharedKey = %s\n", psk);
            sb.append_printf ("AllowedIPs = %s\n", amnezia_allowed_ips (last));
            if (host != "" && port != "") sb.append_printf ("Endpoint = %s:%s\n", host.contains (":") ? "[" + host + "]" : host, port);
            string keepalive = Util.j_str (last, "persistent_keep_alive");
            if (keepalive != "") sb.append_printf ("PersistentKeepalive = %s\n", keepalive);
            return sb.str;
        }

        private static string amnezia_allowed_ips (Json.Object last) {
            if (!last.has_member ("allowed_ips") || last.get_member ("allowed_ips").get_node_type () != Json.NodeType.ARRAY)
                return "0.0.0.0/0, ::/0";
            var ips = new GLib.GenericArray<string> ();
            foreach (var n in last.get_array_member ("allowed_ips").get_elements ()) {
                if (n.get_node_type () == Json.NodeType.VALUE && n.get_value_type () == typeof (string)) ips.add (n.get_string ());
            }
            return ips.length > 0 ? string.joinv (", ", ips.data) : "0.0.0.0/0, ::/0";
        }

        private static Json.Object? parse_object (string text) {
            if (text == "") return null;
            var parser = new Json.Parser ();
            try { parser.load_from_data (text); } catch (GLib.Error e) { return null; }
            var root = parser.get_root ();
            return root != null && root.get_node_type () == Json.NodeType.OBJECT ? root.get_object () : null;
        }

        private static string first_nonempty (string a, string b) {
            return a != "" ? a : b;
        }

        public string to_wg_conf () {
            var sb = new GLib.StringBuilder ();
            sb.append ("[Interface]\n");
            sb.append ("PrivateKey = %s\n".printf (wg.private_key));
            if (wg.local_address != "") sb.append ("Address = %s\n".printf (wg.local_address));
            if (wg.dns != "") sb.append ("DNS = %s\n".printf (wg.dns));
            if (wg.mtu > 0) sb.append ("MTU = %d\n".printf (wg.mtu));
            foreach (var k in AWG_KEYS) {
                string? v = wg.awg.lookup (k.down ());
                if (v != null) sb.append ("%s = %s\n".printf (k, v));
            }
            sb.append ("\n[Peer]\n");
            sb.append ("PublicKey = %s\n".printf (wg.peer_public_key));
            if (wg.preshared_key != "") sb.append ("PresharedKey = %s\n".printf (wg.preshared_key));
            sb.append ("AllowedIPs = %s\n".printf (wg.allowed_ips != "" ? wg.allowed_ips : "0.0.0.0/0, ::/0"));
            sb.append ("Endpoint = %s\n".printf (host_port ()));
            if (wg.keepalive != "") sb.append ("PersistentKeepalive = %s\n".printf (wg.keepalive));
            return sb.str;
        }

        public void to_json (Json.Builder b) {
            b.begin_object ();
            b.set_member_name ("name");           b.add_string_value (name);
            b.set_member_name ("protocol");       b.add_string_value (protocol);
            b.set_member_name ("address");        b.add_string_value (address);
            b.set_member_name ("port");           b.add_int_value (port);
            b.set_member_name ("uuid");           b.add_string_value (uuid);
            if (encryption != "") { b.set_member_name ("encryption"); b.add_string_value (encryption); }
            b.set_member_name ("method");         b.add_string_value (method);
            b.set_member_name ("network");        b.add_string_value (network);
            b.set_member_name ("tls");            b.add_boolean_value (tls);
            b.set_member_name ("sni");            b.add_string_value (sni);
            b.set_member_name ("ws_path");        b.add_string_value (ws_path);
            b.set_member_name ("ws_host");        b.add_string_value (ws_host);
            b.set_member_name ("grpc_service");   b.add_string_value (grpc_service);
            b.set_member_name ("flow");           b.add_string_value (flow);
            b.set_member_name ("fp");             b.add_string_value (fp);
            b.set_member_name ("alpn");           b.add_string_value (alpn);
            b.set_member_name ("allow_insecure"); b.add_boolean_value (allow_insecure);
            b.set_member_name ("reality");        b.add_boolean_value (reality);
            b.set_member_name ("pbk");            b.add_string_value (pbk);
            b.set_member_name ("sid");            b.add_string_value (sid);
            if (password != "") { b.set_member_name ("password"); b.add_string_value (password); }
            if (obfs != "") { b.set_member_name ("obfs"); b.add_string_value (obfs); }
            if (obfs_password != "") { b.set_member_name ("obfs_password"); b.add_string_value (obfs_password); }
            if (congestion_control != "") { b.set_member_name ("congestion_control"); b.add_string_value (congestion_control); }
            if (udp_relay_mode != "") { b.set_member_name ("udp_relay_mode"); b.add_string_value (udp_relay_mode); }
            b.set_member_name ("sub_url");        b.add_string_value (sub_url);
            b.set_member_name ("group_name");     b.add_string_value (group_name);
            if (auto_hosts != "") { b.set_member_name ("auto_hosts"); b.add_string_value (auto_hosts); }
            if (xray_json != "") { b.set_member_name ("xray_json"); b.add_string_value (xray_json); }
            if (is_wireguard () && wg != null) {
                b.set_member_name ("wg");
                b.begin_object ();
                b.set_member_name ("private_key");     b.add_string_value (wg.private_key);
                b.set_member_name ("peer_public_key"); b.add_string_value (wg.peer_public_key);
                b.set_member_name ("preshared_key");   b.add_string_value (wg.preshared_key);
                b.set_member_name ("local_address");   b.add_string_value (wg.local_address);
                b.set_member_name ("allowed_ips");     b.add_string_value (wg.allowed_ips);
                b.set_member_name ("dns");             b.add_string_value (wg.dns);
                b.set_member_name ("mtu");             b.add_int_value (wg.mtu);
                b.set_member_name ("keepalive");
                // awg 3 keepalive can be a range string "min-max" or classic int seconds
                int64 seconds = 0;
                if (int64.try_parse (wg.keepalive, out seconds)) b.add_int_value (seconds);
                else b.add_string_value (wg.keepalive);
                b.set_member_name ("awg");
                b.begin_object ();
                foreach (var k in AWG_KEYS) {
                    string? v = wg.awg.lookup (k.down ());
                    if (v != null) { b.set_member_name (k.down ()); b.add_string_value (v); }
                }
                b.end_object ();
                b.end_object ();
            }
            b.end_object ();
        }

        public static Node from_json (Json.Object o) {
            var n = new Node ();
            n.name = Util.j_str (o, "name");
            n.protocol = Util.j_str (o, "protocol");
            n.address = Util.j_str (o, "address");
            n.port = Util.j_int (o, "port");
            n.uuid = Util.j_str (o, "uuid");
            n.encryption = Util.j_str (o, "encryption");
            n.method = Util.j_str (o, "method");
            n.network = Util.j_str (o, "network");
            if (n.network == "") n.network = "tcp";
            n.tls = Util.j_bool (o, "tls");
            n.sni = Util.j_str (o, "sni");
            n.ws_path = Util.j_str (o, "ws_path");
            n.ws_host = Util.j_str (o, "ws_host");
            n.grpc_service = Util.j_str (o, "grpc_service");
            n.flow = Util.j_str (o, "flow");
            n.fp = Util.j_str (o, "fp");
            n.alpn = Util.j_str (o, "alpn");
            n.allow_insecure = o.has_member ("allow_insecure") ? Util.j_bool (o, "allow_insecure") : true;
            n.reality = Util.j_bool (o, "reality");
            n.pbk = Util.j_str (o, "pbk");
            n.sid = Util.j_str (o, "sid");
            n.password = Util.j_str (o, "password");
            n.obfs = Util.j_str (o, "obfs");
            n.obfs_password = Util.j_str (o, "obfs_password");
            n.congestion_control = Util.j_str (o, "congestion_control");
            n.udp_relay_mode = Util.j_str (o, "udp_relay_mode");
            n.sub_url = Util.j_str (o, "sub_url");
            n.group_name = Util.j_str (o, "group_name");
            n.auto_hosts = Util.j_str (o, "auto_hosts");
            n.xray_json = Util.j_str (o, "xray_json");
            if (n.xray_json != "" && (n.protocol == "xray-json" || n.protocol == "" || (!n.reality && !n.tls))) {
                n.parse_xray_json_fields (n.xray_json);
            }
            if (o.has_member ("wg") && o.get_member ("wg").get_node_type () == Json.NodeType.OBJECT) {
                var w = o.get_object_member ("wg");
                n.wg = new WgConfig ();
                n.wg.private_key = Util.j_str (w, "private_key");
                n.wg.peer_public_key = Util.j_str (w, "peer_public_key");
                n.wg.preshared_key = Util.j_str (w, "preshared_key");
                n.wg.local_address = Util.j_str (w, "local_address");
                n.wg.allowed_ips = Util.j_str (w, "allowed_ips");
                n.wg.dns = Util.j_str (w, "dns");
                n.wg.mtu = Util.j_int (w, "mtu");
                n.wg.keepalive = Util.j_str (w, "keepalive");
                if (n.wg.keepalive == "0") n.wg.keepalive = "";
                if (w.has_member ("awg") && w.get_member ("awg").get_node_type () == Json.NodeType.OBJECT) {
                    var a = w.get_object_member ("awg");
                    foreach (var k in a.get_members ()) n.wg.awg.insert (k, Util.j_str (a, k));
                }
            }
            return n;
        }
    }
}
