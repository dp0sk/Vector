using Vector.Subs;
using Vector.Services;
using Vector.Routing;
namespace Vector.Models {

    // central state store: nodes.json, subs.json, and routing.json
    public class Store : GLib.Object {
        public GLib.ListStore nodes = new GLib.ListStore (typeof (Node));
        public GLib.ListStore groups = new GLib.ListStore (typeof (SubGroup));
        public GLib.ListStore routing_presets = new GLib.ListStore (typeof (RoutingPreset));

        // catch-all group for stray nodes not belonging to any sub
        private const string MANUAL_GROUP = "Manual";

        // suppress UI selection bounce while syncing subscription lists
        public bool syncing { get; private set; default = false; }

        public void load () {
            load_nodes ();
            load_groups ();
            load_routing ();
            update_node_group_names ();
        }

        private void load_nodes () {
            var root = load_json (Paths.nodes_json ());
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
            uint index = 0;
            root.get_array ().foreach_element ((arr, i, el) => {
                if (el.get_node_type () != Json.NodeType.OBJECT) return;
                var n = Node.from_json (el.get_object ());
                n.orig_index = index++;
                nodes.append (n);
            });
        }

        public void save_nodes () {
            var b = new Json.Builder ();
            b.begin_array ();
            for (uint i = 0; i < nodes.get_n_items (); i++) ((Node) nodes.get_item (i)).to_json (b);
            b.end_array ();
            Util.save_json (b, Paths.nodes_json ());
        }

        // figure out which group owns this node (sub url takes precedence, otherwise manual name fallback)
        public string get_node_group_name (Node n) {
            if (n.sub_url == "") {
                return n.group_name != "" && find_group (n.group_name) != null ? n.group_name : MANUAL_GROUP;
            }
            for (uint i = 0; i < groups.get_n_items (); i++) {
                var g = (SubGroup) groups.get_item (i);
                for (uint j = 0; j < g.urls.get_n_items (); j++) {
                    if (g.urls.get_string (j) == n.sub_url) return g.name;
                }
            }
            return MANUAL_GROUP;
        }

        public void update_node_group_names () {
            for (uint i = 0; i < nodes.get_n_items (); i++) {
                var n = (Node) nodes.get_item (i);
                n.orig_index = i;
                n.group_name = get_node_group_name (n);
            }
        }

        // manual nodes only have a dumb string ref to their group, update 'em on rename
        public void rename_manual_nodes (string old_name, string new_name) {
            for (uint i = 0; i < nodes.get_n_items (); i++) {
                var n = (Node) nodes.get_item (i);
                if (n.sub_url == "" && n.group_name == old_name) n.group_name = new_name;
            }
        }

        public void remove_manual_nodes (string group_name) {
            remove_nodes_where ((n) => n.sub_url == "" && n.group_name == group_name);
        }

        public void remove_nodes_of_sub (string url) {
            remove_nodes_where ((n) => n.sub_url == url);
        }

        private delegate bool NodeFilter (Node n);

        private void remove_nodes_where (NodeFilter matches) {
            for (int i = (int) nodes.get_n_items () - 1; i >= 0; i--) {
                if (matches ((Node) nodes.get_item (i))) nodes.remove (i);
            }
            update_node_group_names ();
        }

        // sync subscription nodes: update existing in-place to preserve ping/speed
        // test results and current UI selection state, append new, remove deleted
        public void sync_sub_nodes (string url, GLib.GenericArray<Node> fresh) {
            syncing = true;
            var existing = new GLib.GenericArray<Node> ();
            for (uint i = 0; i < nodes.get_n_items (); i++) {
                var n = (Node) nodes.get_item (i);
                if (n.sub_url == url) existing.add (n);
            }
            var names = new NameCounts (existing, fresh);
            var matched = new bool[existing.length];

            foreach (var f in fresh) {
                int j = 0;
                while (j < existing.length && (matched[j] || !same_server (existing[j], f, names))) j++;
                if (j < existing.length) {
                    existing[j].update_from (f);
                    matched[j] = true;
                } else {
                    nodes.append (f);
                }
            }
            for (int j = 0; j < existing.length; j++) {
                uint position = 0;
                if (!matched[j] && nodes.find (existing[j], out position)) nodes.remove (position);
            }
            update_node_group_names ();
            syncing = false;
        }

        // match by addr:port, or by unique name if the provider migrated IPs but kept label
        private static bool same_server (Node existing, Node fresh, NameCounts names) {
            if (existing.address == fresh.address && existing.port == fresh.port) return true;
            return existing.name == fresh.name && names.unique (existing.name);
        }

        // helper to check if a node label is unique enough to trust for IP migration matching
        private class NameCounts {
            private GLib.HashTable<string, int> old_counts = new GLib.HashTable<string, int> (str_hash, str_equal);
            private GLib.HashTable<string, int> new_counts = new GLib.HashTable<string, int> (str_hash, str_equal);

            public NameCounts (GLib.GenericArray<Node> old_nodes, GLib.GenericArray<Node> new_nodes) {
                foreach (var n in old_nodes) old_counts.insert (n.name, old_counts.lookup (n.name) + 1);
                foreach (var n in new_nodes) new_counts.insert (n.name, new_counts.lookup (n.name) + 1);
            }

            public bool unique (string name) {
                return old_counts.lookup (name) == 1 && new_counts.lookup (name) == 1;
            }
        }

        // v2 is {"version": 2, "groups": [...]}. v1 was just a raw JSON array of urls, dump into "Default"
        private void load_groups () {
            var root = load_json (Paths.subs_json ());
            if (root != null && root.get_node_type () == Json.NodeType.ARRAY) {
                var def = new SubGroup ("Default");
                root.get_array ().foreach_element ((arr, i, el) => {
                    if (el.get_node_type () == Json.NodeType.VALUE) def.urls.append (el.get_string ());
                });
                groups.append (def);
                save_subs ();
                return;
            }
            if (root != null && root.get_node_type () == Json.NodeType.OBJECT && root.get_object ().has_member ("groups")) {
                root.get_object ().get_array_member ("groups").foreach_element ((arr, i, el) => {
                    if (el.get_node_type () == Json.NodeType.OBJECT) groups.append (SubGroup.from_json (el.get_object ()));
                });
                return;
            }
            groups.append (new SubGroup ("Default"));
        }

        public void save_subs () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("version");
            b.add_int_value (2);
            b.set_member_name ("groups");
            b.begin_array ();
            for (uint i = 0; i < groups.get_n_items (); i++) ((SubGroup) groups.get_item (i)).to_json (b);
            b.end_array ();
            b.end_object ();
            Util.save_json (b, Paths.subs_json ());
        }

        public SubGroup? find_group (string name) {
            for (uint i = 0; i < groups.get_n_items (); i++) {
                var g = (SubGroup) groups.get_item (i);
                if (g.name == name) return g;
            }
            return null;
        }

        public void move_group (SubGroup g, int new_index) {
            uint old_index = 0;
            if (!groups.find (g, out old_index) || old_index == new_index) return;
            new_index = new_index.clamp (0, (int) groups.get_n_items () - 1);
            groups.remove (old_index);
            groups.insert (new_index, g);
            save_subs ();
            update_node_group_names ();
        }

        private void load_routing () {
            var root = load_json (Paths.routing_json ());
            if (root != null && root.get_node_type () == Json.NodeType.ARRAY) {
                root.get_array ().foreach_element ((arr, i, el) => {
                    if (el.get_node_type () != Json.NodeType.OBJECT) return;
                    var p = RoutingPreset.from_json (el.get_object ());
                    if (p.name == "") p.name = "Preset #%u".printf (routing_presets.get_n_items () + 1);
                    routing_presets.append (p);
                });
            }
            if (routing_presets.get_n_items () == 0) {
                add_default_presets ();
                save_routing ();
                return;
            }
            // need at least one active preset or routing engine will choke
            if (find_active_preset () == null) {
                ((RoutingPreset) routing_presets.get_item (0)).is_active = true;
                save_routing ();
            }
        }

        public void save_routing () {
            var b = new Json.Builder ();
            b.begin_array ();
            for (uint i = 0; i < routing_presets.get_n_items (); i++) {
                ((RoutingPreset) routing_presets.get_item (i)).to_json (b);
            }
            b.end_array ();
            Util.save_json (b, Paths.routing_json ());
        }

        private void add_default_presets () {
            var bypass = new RoutingPreset ("Bypass LAN & Ads");
            bypass.is_active = true;
            bypass.rules.append (domain_rule ("Block Ads", "block", "geosite:category-ads-all"));
            bypass.rules.append (domain_rule ("Block Spying & Telemetry", "block", "geosite:category-telemetry"));
            bypass.rules.append (ip_rule ("Private IPs", "direct", "geoip:private"));
            bypass.rules.append (domain_rule ("Private Domains", "direct", "geosite:private"));
            bypass.rules.append (new RoutingRule ("Proxy All", "proxy"));
            routing_presets.append (bypass);

            var global = new RoutingPreset ("Global Proxy");
            global.rules.append (new RoutingRule ("Proxy All", "proxy"));
            routing_presets.append (global);
        }

        private static RoutingRule domain_rule (string name, string outbound, string domains) {
            var rule = new RoutingRule (name, outbound);
            rule.domains = domains;
            return rule;
        }

        private static RoutingRule ip_rule (string name, string outbound, string ips) {
            var rule = new RoutingRule (name, outbound);
            rule.ips = ips;
            return rule;
        }

        private RoutingPreset? find_active_preset () {
            for (uint i = 0; i < routing_presets.get_n_items (); i++) {
                var p = (RoutingPreset) routing_presets.get_item (i);
                if (p.is_active) return p;
            }
            return null;
        }

        public RoutingPreset? get_active_routing_preset () {
            // fallback to first preset if active wasn't flagged for some reason
            return find_active_preset ()
                ?? (routing_presets.get_n_items () > 0 ? (RoutingPreset) routing_presets.get_item (0) : null);
        }

        public void set_active_routing_preset (RoutingPreset active) {
            for (uint i = 0; i < routing_presets.get_n_items (); i++) {
                var p = (RoutingPreset) routing_presets.get_item (i);
                p.is_active = (p == active || p.id == active.id);
            }
            save_routing ();
        }

        public void add_or_update_preset (RoutingPreset preset) {
            for (uint i = 0; i < routing_presets.get_n_items (); i++) {
                var existing = (RoutingPreset) routing_presets.get_item (i);
                if (existing.name != preset.name) continue;
                existing.domain_strategy = preset.domain_strategy;
                existing.singbox_domain_strategy = preset.singbox_domain_strategy;
                existing.rules.remove_all ();
                for (uint r = 0; r < preset.rules.get_n_items (); r++) {
                    existing.rules.append ((RoutingRule) preset.rules.get_item (r));
                }
                return;
            }
            routing_presets.append (preset);
        }

        private static Json.Node? load_json (string path) {
            var parser = new Json.Parser ();
            try {
                parser.load_from_file (path);
            } catch (GLib.Error e) {
                return null;
            }
            return parser.get_root ();
        }
    }
}
