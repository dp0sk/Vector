using Vector.Models;
using Vector.Services;
namespace Vector.Subs {

    public errordomain SubscriptionError {
        INVALID_URL, PARSE_FAILED
    }

    public class SubscriptionManager : GLib.Object {

        // fetch sub url, run thru subconverter if configured, sync nodes.
        // throw instead of returning 0 so user actually sees an error instead of thinking sub is empty
        public async int update_one (string url, Store store, SubGroup? group = null, AppSettings? settings = null,
                                     bool direct = false) throws GLib.Error {
            if (!url.has_prefix ("http://") && !url.has_prefix ("https://")) {
                throw new SubscriptionError.INVALID_URL ("not an http(s) URL");
            }

            string converter = settings != null ? settings.sub_converter_url.strip () : "";
            string fetch_url = converter != "" ? converted_url (converter, url) : url;
            var bytes = yield HttpClient.fetch (fetch_url, direct, request_headers (group));

            var fresh = parse_nodes (Util.bytes_to_string (bytes), url);
            if (fresh.length == 0 && Util.bytes_to_string (bytes).strip () != "") {
                throw new SubscriptionError.PARSE_FAILED ("no usable entries in the subscription body");
            }
            store.sync_sub_nodes (url, fresh);
            return (int) fresh.length;
        }

        // subconverter url formatter: replaces {0} or %s, or tacks on &url= / ?target=v2ray&url=
        private static string converted_url (string converter, string url) {
            string escaped = GLib.Uri.escape_string (url);
            if (converter.contains ("{0}")) return converter.replace ("{0}", escaped);
            if (converter.contains ("%s")) return converter.printf (escaped);
            if (converter.contains ("?")) return converter + "&url=" + escaped;
            return converter + "?target=v2ray&url=" + escaped;
        }

        // headers for sub reqs. if line doesn't have a colon, default to X-HTTP-Tag header
        private static string[] request_headers (SubGroup? group) {
            string[] headers = {};
            if (group == null) return headers;
            if (group.user_agent.strip () != "") headers += "User-Agent: " + group.user_agent.strip ();
            foreach (var raw in group.headers.replace (";", "\n").split ("\n")) {
                string line = raw.strip ();
                if (line != "") headers += line.contains (":") ? line : "X-HTTP-Tag: " + line;
            }
            return headers;
        }

        // parse sub body: can be plain text links, base64 blob of links, or full-blown
        // json configs (which is what panels spit out when requested with Happ user agent)
        private static GLib.GenericArray<Models.Node> parse_nodes (string body, string url) {
            string trimmed = body.strip ();
            if (trimmed.has_prefix ("[") || trimmed.has_prefix ("{")) {
                var nodes = parse_config_body (trimmed, url);
                if (nodes.length > 0) return nodes;
            }
            string? decoded = Util.decode_b64 (body);
            if (decoded != null) {
                string d = decoded.strip ();
                if (d.has_prefix ("[") || d.has_prefix ("{")) {
                    var nodes = parse_config_body (d, url);
                    if (nodes.length > 0) return nodes;
                }
            }
            string text = decoded != null && decoded.contains ("://") ? decoded : body;
            var nodes = new GLib.GenericArray<Models.Node> ();
            foreach (var line in text.split ("\n")) {
                var n = Models.Node.from_link (line, url);
                if (n != null) nodes.add (n);
            }
            return nodes;
        }

        // handles raw xray config json or array of configs from sub or clipboard
        public static GLib.GenericArray<Models.Node> parse_config_body (string body, string url) {
            var nodes = new GLib.GenericArray<Models.Node> ();
            var parser = new Json.Parser ();
            try { parser.load_from_data (body); } catch (GLib.Error e) { return nodes; }
            var root = parser.get_root ();
            if (root == null) return nodes;
            if (root.get_node_type () == Json.NodeType.OBJECT) {
                var n = Models.Node.from_xray_json (body, url);
                if (n != null) nodes.add (n);
                return nodes;
            }
            if (root.get_node_type () != Json.NodeType.ARRAY) return nodes;
            foreach (var el in root.get_array ().get_elements ()) {
                if (el.get_node_type () != Json.NodeType.OBJECT) continue;
                var gen = new Json.Generator ();
                gen.root = el;
                gen.pretty = false;
                var n = Models.Node.from_xray_json (gen.to_data (null), url);
                if (n != null) nodes.add (n);
            }
            return nodes;
        }
    }
}
