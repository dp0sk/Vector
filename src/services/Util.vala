namespace Vector.Services {

    public class Util : GLib.Object {



        public static string format_speed (int kbps) {
            double mbs = kbps / 1024.0;
            return mbs >= 10.0 ? "%.0f MB/s".printf (mbs) : "%.1f MB/s".printf (mbs);
        }

        [CCode (cname = "prctl", cheader_filename = "sys/prctl.h")]
        private static extern int prctl (int option, ulong arg2, ulong arg3 = 0, ulong arg4 = 0, ulong arg5 = 0);
        private const int PR_SET_PDEATHSIG = 1;

        // child_setup hook: make sure child gets SIGTERM if we die or crash
        // so we don't leak orphaned core processes
        public static void die_with_parent () {
            prctl (PR_SET_PDEATHSIG, Posix.Signal.TERM);
        }

        // find default ipv4 iface with lowest metric in main table.
        // tun router puts its routing table elsewhere, so this still points to physical eth/wlan
        public static string default_interface () {
            string best = "";
            int64 best_metric = int64.MAX;
            try {
                string table;
                GLib.FileUtils.get_contents ("/proc/net/route", out table);
                foreach (var line in table.split ("\n")) {
                    string[] f = {};
                    foreach (var part in line.split_set (" \t")) if (part != "") f += part;
                    if (f.length < 7 || f[1] != "00000000") continue;
                    if ((uint64.parse (f[3], 16) & 1) == 0) continue; // RTF_UP
                    int64 metric = int64.parse (f[6]);
                    if (metric < best_metric) { best = f[0]; best_metric = metric; }
                }
            } catch (GLib.Error e) {}
            return best;
        }

        public static string? decode_b64 (string input) {
            var data = decode_b64_bytes (input);
            if (data == null) return null;
            string text = bytes_to_string (new GLib.Bytes (data));
            return text.validate () ? text : null;
        }

        public static string mask_url (string url) {
            int q = url.index_of ("?");
            string base_part = q >= 0 ? url.substring (0, q) : url;
            string query_part = q >= 0 ? "?masked" : "";
            if (q >= 0) {
                int h = url.index_of ("#", q);
                if (h >= 0) query_part += url.substring (h);
            }
            int scheme_end = base_part.index_of ("://");
            if (scheme_end > 0) {
                int at = base_part.index_of ("@", scheme_end + 3);
                int slash = base_part.index_of ("/", scheme_end + 3);
                if (at > 0 && (slash < 0 || at < slash)) {
                    base_part = base_part.substring (0, scheme_end + 3) + "***@" + base_part.substring (at + 1);
                }
            }
            return base_part + query_part;
        }

        // handle url-safe base64 and fix missing '=' padding if provider omitted it
        public static uint8[]? decode_b64_bytes (string input) {
            string s = input.strip ()
                .replace ("-", "+").replace ("_", "/")
                .replace ("\n", "").replace ("\r", "").replace (" ", "");
            switch (s.length % 4) {
                case 2: s += "=="; break;
                case 3: s += "=";  break;
                case 1: return null;
            }
            var data = GLib.Base64.decode (s);
            return data.length > 0 ? data : null;
        }

        public static uint8[]? zlib_inflate (uint8[] data) {
            try {
                var input = new GLib.ConverterInputStream (
                    new GLib.MemoryInputStream.from_bytes (new GLib.Bytes (data)),
                    new GLib.ZlibDecompressor (GLib.ZlibCompressorFormat.ZLIB));
                var output = new GLib.MemoryOutputStream.resizable ();
                output.splice (input, GLib.OutputStreamSpliceFlags.CLOSE_SOURCE | GLib.OutputStreamSpliceFlags.CLOSE_TARGET);
                return output.steal_as_bytes ().get_data ();
            } catch (GLib.Error e) {
                return null;
            }
        }

        public static string[] split_list (string raw) {
            var tmp = new GLib.GenericArray<string> ();
            foreach (var part in raw.replace ("\n", ",").replace (";", ",").split (",")) {
                var p = part.strip ();
                if (p != "") tmp.add (p);
            }
            var result = new string[tmp.length];
            for (int i = 0; i < (int) tmp.length; i++) result[i] = tmp[i];
            return result;
        }

        public static string j_str (Json.Object o, string name) {
            if (!o.has_member (name)) return "";
            var m = o.get_member (name);
            if (m.get_node_type () != Json.NodeType.VALUE) return "";
            GLib.Type t = m.get_value_type ();
            if (t == typeof (string)) return m.get_string () ?? "";
            if (t == typeof (int64)) return m.get_int ().to_string ();
            return "";
        }

        public static int j_int (Json.Object o, string name) {
            return int.parse (j_str (o, name));
        }

        public static bool j_bool (Json.Object o, string name) {
            if (!o.has_member (name)) return false;
            var m = o.get_member (name);
            if (m.get_node_type () != Json.NodeType.VALUE) return false;
            if (m.get_value_type () == typeof (bool)) return m.get_boolean ();
            return j_str (o, name) == "true";
        }

        public static string to_json_string (Json.Builder b) {
            var gen = new Json.Generator ();
            gen.set_root (b.get_root ());
            gen.pretty = true;
            return gen.to_data (null);
        }

        // 0600 atomic write so other users on a shared box can't read plaintext tokens and passwords
        public static void write_private (string path, string content) throws GLib.FileError {
            GLib.FileUtils.set_contents_full (path, content, -1, GLib.FileSetContentsFlags.CONSISTENT, 0600);
        }

        public static void save_json (Json.Builder b, string path) {
            try {
                write_private (path, to_json_string (b));
            } catch (GLib.Error e) {
                warning ("Failed to save json to %s: %s", path, e.message);
            }
        }

        // GLib.Bytes is NOT null-terminated! don't cast data pointer directly or vala reads random garbage
        public static string bytes_to_string (GLib.Bytes bytes) {
            var sb = new GLib.StringBuilder.sized (bytes.get_size () + 1);
            sb.append_len ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            return sb.str;
        }


        public static async void sleep_ms (uint ms) {
            GLib.Timeout.add (ms, () => {
                sleep_ms.callback ();
                return GLib.Source.REMOVE;
            });
            yield;
        }

        public static async int run_command (string[] argv, out string output) {
            output = "";
            try {
                var proc = new GLib.Subprocess.newv (argv,
                    GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_MERGE);
                string? text = null;
                yield proc.communicate_utf8_async (null, null, out text, null);
                output = (text ?? "").strip ();
                return proc.get_if_exited () ? proc.get_exit_status () : -1;
            } catch (GLib.Error e) {
                output = e.message;
                return -1;
            }
        }

        public static string make_tmp_path (string prefix, uint16 port) {
            return GLib.Path.build_filename (
                Paths.runtime_dir (),
                "%s-%d-%u.json".printf (prefix, (int) Posix.getpid (), port));
        }


    }
}
