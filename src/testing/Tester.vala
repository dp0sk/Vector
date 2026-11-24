using Vector.Models;
using Vector.Engines;
using Vector.Services;
namespace Vector.Testing {

    // probe real latency and throughput through the proxy core instead of useless icmp pings
    public class Tester : GLib.Object {

        public static uint16 ephemeral_port () {
            try {
                var sock = new GLib.Socket (
                    GLib.SocketFamily.IPV4, GLib.SocketType.STREAM, GLib.SocketProtocol.TCP);
                sock.bind (new GLib.InetSocketAddress (
                    new GLib.InetAddress.loopback (GLib.SocketFamily.IPV4), 0), true);
                var addr = (GLib.InetSocketAddress) sock.get_local_address ();
                uint16 port = (uint16) addr.get_port ();
                sock.close ();
                return port;
            } catch (GLib.Error e) {
                return 0;
            }
        }

        // wait up to 2.5s for previous core to release the port.
        // if we try binding while the old process is still shutting down, everything blows up
        public static async bool wait_port_free (uint16 port) {
            for (int i = 0; i < 25 && port_open_sync (port); i++) yield Util.sleep_ms (100);
            return !port_open_sync (port);
        }

        public static string port_taken_message (uint16 port) {
            return "port %u is taken by another program (see: ss -ltnp 'sport = :%u')".printf (port, port);
        }

        public static bool port_open_sync (uint16 port) {
            try {
                var sock = new GLib.Socket (
                    GLib.SocketFamily.IPV4, GLib.SocketType.STREAM, GLib.SocketProtocol.TCP);
                sock.bind (new GLib.InetSocketAddress (
                    new GLib.InetAddress.loopback (GLib.SocketFamily.IPV4), port), true); // reuseaddr so TIME_WAIT sockets don't trick us
                sock.close ();
                return false;
            } catch (GLib.Error e) {
                return true;
            }
        }

        // poll until the proxy core actually starts accepting conns on the port
        public static async bool wait_for_port (uint16 port, int tries = 60, GLib.Cancellable? cancellable = null) {
            for (int i = 0; i < tries; i++) {
                if (cancellable != null && cancellable.is_cancelled ()) return false;
                var client = new GLib.SocketClient ();
                client.timeout = 1;
                try {
                    var conn = yield client.connect_async (
                        new GLib.InetSocketAddress (
                            new GLib.InetAddress.loopback (GLib.SocketFamily.IPV4), port),
                        cancellable);
                    try { conn.close (); } catch (GLib.Error e) {}
                    return true;
                } catch (GLib.Error e) {
                    if (cancellable != null && cancellable.is_cancelled ()) return false;
                    yield Util.sleep_ms (100);
                }
            }
            return false;
        }

        // measure HTTP RTT over SOCKS5. socks5 avoids http connect proxy tunnel overhead
        public static async int probe_latency (uint16 port, string url = "https://www.google.com/generate_204", int timeout_sec = 10, GLib.Cancellable? cancellable = null) {
            string target = url.strip () != "" ? url.strip () : "https://www.google.com/generate_204";
            var req = new ProxiedRequest (port, target, timeout_sec, cancellable);
            if (!req.usable) { req.finish (); return -2; }
            var timer = new GLib.Timer ();
            try {
                var stream = yield req.session.send_async (req.message, GLib.Priority.DEFAULT, req.cancellable);
                int elapsed = (int) (timer.elapsed () * 1000.0);
                try { stream.close (); } catch (GLib.Error e) {}
                return req.message.status_code >= 200 && req.message.status_code < 400 ? elapsed : -2;
            } catch (GLib.Error e) {
                return -2;
            } finally {
                req.finish ();
            }
        }

        // measure transfer speed: start timer after headers arrive to exclude TTFB
        public static async int download_speed_kbps (int port, string url = "https://speed.cloudflare.com/__down?bytes=10000000", int timeout_sec = 10, GLib.Cancellable? cancellable = null) {
            var req = new ProxiedRequest (port, url, timeout_sec, cancellable);
            if (!req.usable) { req.finish (); return -2; }
            try {
                var stream = yield req.session.send_async (req.message, GLib.Priority.DEFAULT, req.cancellable);
                if (req.message.status_code < 200 || req.message.status_code >= 400) {
                    try { stream.close (); } catch (GLib.Error e) {}
                    return -2;
                }
                var timer = new GLib.Timer ();
                int64 total = 0;
                var buf = new uint8[65536];
                while (!req.cancellable.is_cancelled () && timer.elapsed () <= 5.0) {
                    ssize_t n;
                    try {
                        n = yield stream.read_async (buf, GLib.Priority.DEFAULT, req.cancellable);
                    } catch (GLib.Error e) {
                        break; // timed out or core hung mid-transfer: calculate speed on whatever data we managed to grab
                    }
                    if (n <= 0) break;
                    total += n;
                }
                try { stream.close (); } catch (GLib.Error e) {}
                double secs = timer.elapsed ();
                if (secs <= 0.0 || total == 0) return -2;
                return (int) ((total / 1024.0) / secs);
            } catch (GLib.Error e) {
                return -2;
            } finally {
                req.finish ();
            }
        }

        private static async string? proxied_text (int proxy_port, string url, int timeout_sec,
                                                   GLib.Cancellable? cancellable) {
            var req = new ProxiedRequest (proxy_port, url, timeout_sec, cancellable);
            if (!req.usable) { req.finish (); return null; }
            try {
                var bytes = yield req.session.send_and_read_async (req.message, GLib.Priority.DEFAULT, req.cancellable);
                if (req.message.status_code < 200 || req.message.status_code >= 300) return null;
                return Util.bytes_to_string (bytes).strip ();
            } catch (GLib.Error e) {
                return null;
            } finally {
                req.finish ();
            }
        }

        private static string country_code_or_empty (string code) {
            string c = code.strip ().up ();
            if (c.length != 2 || !c[0].isalpha () || !c[1].isalpha ()) return "";
            return c;
        }

        // deal with differing json schemas across ipinfo / ip-api / ipapi.is
        private static string country_from_json (Json.Object obj) {
            foreach (var key in new string[] { "country_code", "countryCode", "country" }) {
                if (obj.has_member (key)) {
                    string c = country_code_or_empty (Util.j_str (obj, key));
                    if (c != "") return c;
                }
            }
            if (obj.has_member ("location")) {
                var loc = obj.get_member ("location");
                if (loc.get_node_type () == Json.NodeType.OBJECT) return country_from_json (loc.get_object ());
            }
            return "";
        }

        public static async ExternalIpResult check_external_ip (int proxy_port, string test_url = "https://api.ipify.org?format=text",
                                                                int timeout_sec = 10, GLib.Cancellable? cancellable = null) {
            string url = test_url.strip () != "" ? test_url.strip () : "https://api.ipify.org?format=text";
            var timer = new GLib.Timer ();
            string? body = yield proxied_text (proxy_port, url, timeout_sec, cancellable);
            if (body == null) return new ExternalIpResult ("", -1);
            int elapsed = (int) (timer.elapsed () * 1000.0);

            string ip = body;
            string country = "";
            if (body.has_prefix ("{")) parse_ip_info (body, ref ip, out country);
            if (ip.length > 50) ip = ip.substring (0, 50); // clamp error response length so it doesn't break the UI

            var result = new ExternalIpResult (ip, elapsed);
            result.country = country;
            return result;
        }

        private static void parse_ip_info (string json, ref string ip, out string country) {
            country = "";
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json);
            } catch (GLib.Error e) {
                return;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;
            var obj = root.get_object ();
            if (obj.has_member ("ip")) ip = Util.j_str (obj, "ip");
            else if (obj.has_member ("query")) ip = Util.j_str (obj, "query");
            country = country_from_json (obj);
        }

        public static async string lookup_country (int proxy_port, string ip, int timeout_sec = 10,
                                                   GLib.Cancellable? cancellable = null) {
            string q = GLib.Uri.escape_string (ip.strip (), ":", false);
            if (q == "") return "";
            foreach (var url in new string[] {
                "https://ipinfo.io/%s/country".printf (q),
                "https://ipapi.co/%s/country/".printf (q)
            }) {
                if (cancellable != null && cancellable.is_cancelled ()) return "";
                string? body = yield proxied_text (proxy_port, url, timeout_sec, cancellable);
                string c = body != null ? country_code_or_empty (body) : "";
                if (c != "") return c;
            }
            return "";
        }

        // spin up a disposable core on an ephemeral port to benchmark this specific node
        public static async void probe_node (Models.Node node, string core, string bin, string ping_url,
                                             string speed_url, bool with_speed, int timeout_sec,
                                             GLib.Cancellable? cancellable,
                                             out int lat, out int spd) {
            lat = -2;
            spd = -1;
            uint16 port = ephemeral_port ();
            if (port == 0) return;
            string cfg = ConfigGenerator.gen_test_for (core, node, port);
            string cfg_path = Util.make_tmp_path ("vector-test", port);
            try {
                Util.write_private (cfg_path, cfg);
            } catch (GLib.Error e) {
                return;
            }
            GLib.Subprocess? proc = null;
            try {
                var launcher = new GLib.SubprocessLauncher (
                    GLib.SubprocessFlags.STDOUT_SILENCE | GLib.SubprocessFlags.STDERR_SILENCE);
                // ensure child core process terminates if parent exits
                launcher.set_child_setup (() => { Util.die_with_parent (); });
                proc = launcher.spawnv ({ bin, "run", "-c", cfg_path });
            } catch (GLib.Error e) {
                proc = null;
            }
            if (proc != null) {
                if (yield wait_for_port (port, 50, cancellable)) {
                    lat = yield probe_latency (port, ping_url, timeout_sec, cancellable);
                    if (with_speed && lat > 0) {
                        spd = yield download_speed_kbps (port, speed_url, timeout_sec, cancellable);
                    }
                }
                yield kill_proc (proc);
            }
            GLib.FileUtils.unlink (cfg_path);
        }

        // send SIGTERM, fallback to SIGKILL after 2 seconds
        public static async void kill_proc (GLib.Subprocess proc) {
            proc.send_signal (Posix.Signal.TERM);
            bool exited = false;
            GLib.Timeout.add (2000, () => {
                if (!exited) proc.force_exit ();
                return GLib.Source.REMOVE;
            });
            try { yield proc.wait_async (null); } catch (GLib.Error e) {}
            exited = true;
        }
    }

    // wraps a single socks5 request with timeout cancellation
    private class ProxiedRequest : GLib.Object {
        public Soup.Session session;
        public Soup.Message? message;
        public GLib.Cancellable cancellable = new GLib.Cancellable ();
        public bool usable { get { return message != null && !cancellable.is_cancelled (); } }

        private GLib.Cancellable? parent;
        private ulong parent_handler = 0;
        private uint timeout_id = 0;

        public ProxiedRequest (int port, string url, int timeout_sec, GLib.Cancellable? parent) {
            int timeout = timeout_sec > 0 ? timeout_sec : 10;
            session = new Soup.Session ();
            session.timeout = timeout;
            session.proxy_resolver = new GLib.SimpleProxyResolver ("socks5://127.0.0.1:%d".printf (port), null);
            message = new Soup.Message ("GET", url);

            this.parent = parent;
            if (parent != null) {
                if (parent.is_cancelled ()) cancellable.cancel ();
                parent_handler = parent.connect (() => { cancellable.cancel (); });
            }
            timeout_id = GLib.Timeout.add_seconds (timeout, () => {
                timeout_id = 0; // timer fired: don't double-remove in finish()
                cancellable.cancel ();
                return GLib.Source.REMOVE;
            });
        }

        public void finish () {
            if (timeout_id != 0) GLib.Source.remove (timeout_id);
            timeout_id = 0;
            if (parent != null && parent_handler != 0) parent.disconnect (parent_handler);
            parent_handler = 0;
            session.abort ();
        }
    }

    public class ExternalIpResult : GLib.Object {
        public string ip;
        public int latency_ms;
        public string country = "";
        public ExternalIpResult (string ip, int latency_ms) {
            this.ip = ip;
            this.latency_ms = latency_ms;
        }
    }
}
