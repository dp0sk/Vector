using Vector.Services;
namespace Vector.Routing {

    // pulls routing presets from remote urls. handles v2rayN templates (json with "routingItems"),
    // raw preset objects/arrays, or bare rule arrays. Falls back through jsdelivr mirrors
    // when raw github gets rate-limited or blocked
    public class RoutingRulesFetcher : GLib.Object {

        public const string DEFAULT_SOURCE =
            "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-custom-routing-list/refs/heads/main/v2rayN/all.json";

        public signal void log_line (string line);

        private const string[] RULE_KEYS = {
            "outboundTag", "outbound_tag", "domain", "domains", "ip", "ips", "port", "protocol", "network"
        };
        // peek keys to see if this is an array of rules vs presets
        private const string[] RULES_ARRAY_KEYS = { "outboundTag", "outbound_tag", "domain", "ip", "port" };
        private const string[] PRESET_RULES_KEYS = { "rules", "ruleList", "customRules" };

        public async GLib.GenericArray<RoutingPreset> fetch (string source_url) throws GLib.Error {
            var bytes = yield download (source_url);
            if (bytes == null) throw new GLib.IOError.FAILED ("could not download %s".printf (source_url));
            var parser = new Json.Parser ();
            parser.load_from_data (Util.bytes_to_string (bytes));
            var root = parser.get_root ();
            if (root == null) throw new GLib.IOError.INVALID_DATA ("empty JSON from %s".printf (source_url));

            var result = new GLib.GenericArray<RoutingPreset> ();
            if (root.get_node_type () == Json.NodeType.OBJECT) {
                var obj = root.get_object ();
                if (obj.has_member ("routingItems")) {
                    yield fetch_template_items (obj.get_array_member ("routingItems"), result);
                } else {
                    add_if_has_rules (result, preset_from_object (obj));
                }
            } else if (root.get_node_type () == Json.NodeType.ARRAY) {
                var arr = root.get_array ();
                if (is_rules_array (arr)) {
                    string preset_name = preset_name_from_url (source_url);
                    add_if_has_rules (result, preset_from_rules (preset_name, "IPIfNonMatch", arr));
                } else {
                    arr.foreach_element ((a, i, el) => {
                        if (el.get_node_type () == Json.NodeType.OBJECT) {
                            add_if_has_rules (result, preset_from_object (el.get_object ()));
                        }
                    });
                }
            }
            return result;
        }

        // v2rayN template: each item is a pointer to another url holding the actual rules array
        private async void fetch_template_items (Json.Array items, GLib.GenericArray<RoutingPreset> result) {
            for (uint i = 0; i < items.get_length (); i++) {
                var el = items.get_element (i);
                if (el.get_node_type () != Json.NodeType.OBJECT) continue;
                var item = el.get_object ();
                string name = Util.j_str (item, "remarks");
                string url = Util.j_str (item, "url");
                if (url == "") continue;

                log_line ("[app] fetching preset '%s' from %s".printf (name, url));
                var bytes = yield download (url);
                if (bytes == null) {
                    log_line ("[app] failed to download preset '%s' from %s".printf (name, url));
                    continue;
                }
                var rules = parse_array (Util.bytes_to_string (bytes));
                var preset = rules != null
                    ? preset_from_rules (name != "" ? name : "Fetched Ruleset", Util.j_str (item, "domainStrategy"), rules)
                    : null;
                if (preset != null && preset.rules.get_n_items () > 0) {
                    result.add (preset);
                    log_line ("[app] added preset '%s' (%u rules)".printf (preset.name, preset.rules.get_n_items ()));
                } else {
                    log_line ("[app] failed to parse rules for preset '%s'".printf (name));
                }
            }
        }

        private static void add_if_has_rules (GLib.GenericArray<RoutingPreset> result, RoutingPreset? preset) {
            if (preset != null && preset.rules.get_n_items () > 0) result.add (preset);
        }

        private async GLib.Bytes? download (string url) {
            foreach (var mirror in mirror_urls (url)) {
                try {
                    return yield HttpClient.fetch (mirror, false, { "Accept: */*" }, 15);
                } catch (GLib.Error e) {
                    log_line ("[app] %s: %s".printf (mirror, e.message));
                }
            }
            return null;
        }

        // github raw gets blocked or throttled to hell, try jsdelivr fastly/gcore cdn mirrors
        private static string[] mirror_urls (string url) {
            const string JSDELIVR = "https://cdn.jsdelivr.net/";
            string[] urls = { url };
            string? cdn = jsdelivr_url (url);
            if (cdn == null && url.has_prefix (JSDELIVR)) cdn = url;
            if (cdn != null) {
                if (cdn != url) urls += cdn;
                urls += cdn.replace (JSDELIVR, "https://fastly.jsdelivr.net/");
                urls += cdn.replace (JSDELIVR, "https://gcore.jsdelivr.net/");
            }
            return urls;
        }

        // rewrite raw.githubusercontent.com into jsdelivr gh url format
        private static string? jsdelivr_url (string url) {
            const string RAW = "https://raw.githubusercontent.com/";
            if (!url.has_prefix (RAW)) return null;
            string[] parts = url.substring (RAW.length).split ("/");
            if (parts.length < 3) return null;
            bool refs_heads = parts.length >= 5 && parts[2] == "refs" && parts[3] == "heads";
            string branch = refs_heads ? parts[4] : parts[2];
            int path_start = refs_heads ? 5 : 3;
            string path = string.joinv ("/", parts[path_start:parts.length]);
            if (branch == "" || path == "") return null;
            return "https://cdn.jsdelivr.net/gh/%s/%s@%s/%s".printf (parts[0], parts[1], branch, path);
        }

        private static Json.Array? parse_array (string text) {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (text);
            } catch (GLib.Error e) {
                return null;
            }
            var root = parser.get_root ();
            return root != null && root.get_node_type () == Json.NodeType.ARRAY ? root.get_array () : null;
        }

        private static bool is_rules_array (Json.Array arr) {
            if (arr.get_length () == 0) return false;
            var first = arr.get_element (0);
            return first.get_node_type () == Json.NodeType.OBJECT && has_any (first.get_object (), RULES_ARRAY_KEYS);
        }

        private static RoutingPreset preset_from_rules (string name, string domain_strategy, Json.Array rules) {
            var preset = new RoutingPreset (name);
            if (domain_strategy != "") preset.domain_strategy = domain_strategy;
            add_rules (preset, rules);
            return preset;
        }

        private static string preset_name_from_url (string url) {
            string lower = url.down ();
            if (lower.contains ("whitelist")) return "China Whitelist";
            if (lower.contains ("blacklist")) return "China Blacklist";
            if (lower.contains ("custom_routing_rules")) return "China Routing";
            if (lower.has_suffix ("/all.json") || lower.has_suffix ("all.json")) return "Global (Bypass LAN & Ads)";
            string basename = GLib.Path.get_basename (url);
            if (basename != "" && !basename.contains ("?") && !basename.contains ("=")) {
                if (basename.has_suffix (".json")) basename = basename.substring (0, basename.length - 5);
                return basename;
            }
            return "Fetched Ruleset";
        }

        // handle Vector's preset format or external json formats (v2rayN/clash/xray keys)
        private static RoutingPreset preset_from_object (Json.Object obj) {
            if (obj.has_member ("rules") && obj.has_member ("singbox_domain_strategy")) {
                return RoutingPreset.from_json (obj);
            }
            string name = first_value (obj, { "name", "remarks", "title" });
            var preset = new RoutingPreset (name != "" ? name : "Fetched Preset");
            string domain_strategy = Util.j_str (obj, "domainStrategy");
            if (domain_strategy != "") preset.domain_strategy = domain_strategy;

            foreach (var key in PRESET_RULES_KEYS) {
                if (obj.has_member (key)) {
                    add_rules (preset, obj.get_array_member (key));
                    return preset;
                }
            }
            var single = rule_from_object (obj);
            if (single != null) preset.rules.append (single);
            return preset;
        }

        private static void add_rules (RoutingPreset preset, Json.Array rules) {
            rules.foreach_element ((a, i, el) => {
                if (el.get_node_type () != Json.NodeType.OBJECT) return;
                var rule = rule_from_object (el.get_object ());
                if (rule != null) preset.rules.append (rule);
            });
        }

        // parse rule object: accepts both camelCase and snake_case keys from various sources
        private static RoutingRule? rule_from_object (Json.Object o) {
            if (!has_any (o, RULE_KEYS)) return null;
            var rule = new RoutingRule ();
            rule.remarks = first_value (o, { "remarks", "title" });
            rule.enabled = o.has_member ("enabled") ? Util.j_bool (o, "enabled") : true;
            rule.outbound_tag = first_value (o, { "outboundTag", "outbound_tag" });
            if (rule.outbound_tag == "") rule.outbound_tag = "proxy";
            rule.network = value_text (o, "network");
            rule.port = value_text (o, "port");
            rule.inbound_tag = first_value (o, { "inboundTag", "inbound_tag" });
            rule.protocol = value_text (o, "protocol");
            rule.domains = first_value (o, { "domain", "domains" });
            rule.ips = first_value (o, { "ip", "ips" });
            rule.processes = first_value (o, { "process", "processes" });
            return rule;
        }

        private static bool has_any (Json.Object o, string[] keys) {
            foreach (var key in keys) if (o.has_member (key)) return true;
            return false;
        }

        private static string first_value (Json.Object o, string[] keys) {
            foreach (var key in keys) {
                string text = value_text (o, key);
                if (text != "") return text;
            }
            return "";
        }

        // stringify whatever json-glib gave us (scalar or array -> comma-separated string)
        private static string value_text (Json.Object o, string key) {
            if (!o.has_member (key)) return "";
            var node = o.get_member (key);
            if (node.get_node_type () == Json.NodeType.ARRAY) {
                var text = new GLib.StringBuilder ();
                node.get_array ().foreach_element ((a, i, el) => {
                    if (el.get_node_type () != Json.NodeType.VALUE) return;
                    if (text.len > 0) text.append (", ");
                    text.append (scalar_text (el));
                });
                return text.str;
            }
            if (node.get_node_type () != Json.NodeType.VALUE) return "";
            if (node.get_value_type () == typeof (bool)) return node.get_boolean ().to_string ();
            return scalar_text (node);
        }

        private static string scalar_text (Json.Node node) {
            if (node.get_value_type () == typeof (int64)) return node.get_int ().to_string ();
            if (node.get_value_type () == typeof (string)) return node.get_string ();
            return "";
        }
    }
}
