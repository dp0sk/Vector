using Vector.Engines;
namespace Vector.Services {

    // Normalizes sing-box and xray log output and filters out internal spam.
    // Nasty sing-box timing quirk: when a new connection opens, inbound lines are logged
    // before sing-box resolves the process path. We have to buffer lines by connection ID
    // until we find out whether it's our own engine/tester process (so we can drop the noise).
    public class LogFormatter : GLib.Object {

        private GLib.Regex sb_re;
        private GLib.Regex xr_re;
        private GLib.Regex ansi_re;
        // conn id -> lines buffered until sing-box figures out who opened it
        private GLib.HashTable<string, GLib.GenericArray<string>> held =
            new GLib.HashTable<string, GLib.GenericArray<string>> (str_hash, str_equal);
        private GLib.HashTable<string, bool> engine_ids = new GLib.HashTable<string, bool> (str_hash, str_equal);

        construct {
            try {
                sb_re = new GLib.Regex ("""^[+-]\d{4} \d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2}) ([A-Z]+) (?:\[(\d+) [^\]]*\] )?(.*)$""");
                xr_re = new GLib.Regex ("""^\d{4}/\d{2}/\d{2} (\d{2}:\d{2}:\d{2})(?:\.\d+)? \[(\w+)\] (?:\[\d+\] )?(.*)$""");
                ansi_re = new GLib.Regex ("""\x1b\[[0-9;]*[A-Za-z]""");
            } catch (GLib.RegexError e) {
                GLib.error ("LogFormatter regex: %s", e.message);
            }
        }

        private static bool is_engine_path (string path) {
            string base_name = GLib.Path.get_basename (path.strip ());
            foreach (var n in ConfigGenerator.ENGINE_PROCESS_NAMES) {
                if (base_name == n) return true;
            }
            return false;
        }

        private static string level_of (string raw) {
            switch (raw.down ()) {
                case "warning": case "warn": return "WARN";
                case "error":                return "ERROR";
                case "fatal": case "panic":  return "FATAL";
                case "debug": case "trace":  return "DEBUG";
                default:                     return "INFO";
            }
        }

        private void flush_held (GLib.GenericArray<string> out_lines) {
            held.foreach ((id, lines) => {
                foreach (var l in lines) out_lines.add (l);
            });
            held.remove_all ();
        }

        public string[] process (string raw, string source) {
            string line = raw;
            try { line = ansi_re.replace (raw, -1, 0, ""); } catch (GLib.RegexError e) {}
            line = line.strip ();
            if (line == "") return {};

            GLib.MatchInfo m;
            if (sb_re.match (line, 0, out m)) {
                var out_lines = new GLib.GenericArray<string> ();
                process_sing_box (m.fetch (1), level_of (m.fetch (2)), m.fetch (3) ?? "", m.fetch (4), source, out_lines);
                return out_lines.data;
            }
            if (xr_re.match (line, 0, out m)) {
                string msg = m.fetch (3);
                // xray logs its clean startup banner as Warning; downgrade to INFO
                string level = msg.has_prefix ("core: Xray ") && msg.has_suffix (" started") ? "INFO" : level_of (m.fetch (2));
                return { format (m.fetch (1), level, source, msg) };
            }
            if (line.has_prefix ("Xray ") && line.contains ("Penetrates Everything")) return {};
            if (line == "A unified platform for anti-censorship.") return {};
            return { line };
        }

        private static string format (string time, string level, string source, string msg) {
            return "%s %-5s [%s] %s".printf (time, level, source, msg);
        }

        private void process_sing_box (string time, string level, string id, string msg, string source,
                                       GLib.GenericArray<string> out_lines) {
            const string PROCESS_PATH = "router: found process path:";
            if (msg.has_prefix (PROCESS_PATH)) {
                // process path resolved: if it's our engine/tester, drop buffered log line
                string path = msg.substring (PROCESS_PATH.length).split (",")[0];
                if (id == "") return;
                if (is_engine_path (path)) {
                    engine_ids.insert (id, true);
                    held.remove (id);
                } else {
                    release (id, out_lines);
                }
                return;
            }
            if (msg.has_prefix ("router: found user") || msg.has_prefix ("router: found package")) {
                if (id != "") release (id, out_lines);
                return;
            }
            if (id != "" && engine_ids.contains (id)) return;
            if (source == "router" && msg.has_suffix ("socks5: request rejected, code=1")) return;
            if (msg.has_prefix ("router: failed to search process")) return;
            if (msg.has_suffix ("using outbound/block[block]: operation not permitted")) return;
            if (msg.contains ("inbound connection from ") || msg.contains ("inbound packet connection from ")) return;

            string formatted = format (time, level, source, msg);
            if (id != "" && level == "INFO" && msg.has_prefix ("inbound/")) {
                // owner not known yet: hold until process lookup arrives
                var list = held.lookup (id);
                if (list == null) {
                    list = new GLib.GenericArray<string> ();
                    held.insert (id, list);
                }
                list.add (formatted);
                if (held.size () > 200) flush_held (out_lines);
                return;
            }
            if (id != "") release (id, out_lines);
            out_lines.add (formatted);
            if (engine_ids.size () > 5000) engine_ids.remove_all ();
        }

        private void release (string id, GLib.GenericArray<string> out_lines) {
            var list = held.lookup (id);
            if (list == null) return;
            foreach (var l in list) out_lines.add (l);
            held.remove (id);
        }
    }
}
