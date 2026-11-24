using Vector.Services;
namespace Vector.Routing {

    public class RoutingPreset : GLib.Object {
        public string id;
        public string name;
        public bool is_active;
        public string domain_strategy;
        // kept around for json roundtripping; actual singbox configs pull ipv6 mode from AppSettings.ip_mode
        public string singbox_domain_strategy;
        public GLib.ListStore rules = new GLib.ListStore (typeof (RoutingRule));

        public RoutingPreset (string name = "New Routing Preset") {
            this.id = GLib.Uuid.string_random ();
            this.name = name != "" ? name : "New Routing Preset";
            this.is_active = false;
            this.domain_strategy = "AsIs";
            this.singbox_domain_strategy = "prefer_ipv4";
        }

        public static RoutingPreset from_json (Json.Object o) {
            var preset = new RoutingPreset ();
            preset.id = Util.j_str (o, "id");
            if (preset.id == "") preset.id = GLib.Uuid.string_random ();
            preset.name = Util.j_str (o, "name");
            if (preset.name == "") preset.name = Util.j_str (o, "remarks");
            if (preset.name == "") preset.name = "Routing Preset";
            preset.is_active = Util.j_bool (o, "is_active");
            preset.domain_strategy = Util.j_str (o, "domain_strategy");
            if (preset.domain_strategy == "") preset.domain_strategy = "AsIs";
            preset.singbox_domain_strategy = Util.j_str (o, "singbox_domain_strategy");
            if (preset.singbox_domain_strategy == "") preset.singbox_domain_strategy = "prefer_ipv4";

            if (o.has_member ("rules")) {
                var arr = o.get_array_member ("rules");
                arr.foreach_element ((a, i, el) => {
                    if (el.get_node_type () == Json.NodeType.OBJECT) {
                        preset.rules.append (RoutingRule.from_json (el.get_object ()));
                    }
                });
            }
            return preset;
        }

        public void move_rule (RoutingRule r, int new_index) {
            int old_index = -1;
            for (uint i = 0; i < rules.get_n_items (); i++) {
                if (rules.get_item (i) == r) {
                    old_index = (int) i;
                    break;
                }
            }

            if (old_index == -1 || old_index == new_index) return;
            
            if (new_index < 0) new_index = 0;
            if (new_index > rules.get_n_items () - 1) new_index = (int) rules.get_n_items () - 1;

            rules.remove (old_index);
            rules.insert (new_index, r);
        }

        public void to_json (Json.Builder b) {
            b.begin_object ();
            b.set_member_name ("id");                      b.add_string_value (id);
            b.set_member_name ("name");                    b.add_string_value (name);
            b.set_member_name ("is_active");               b.add_boolean_value (is_active);
            b.set_member_name ("domain_strategy");         b.add_string_value (domain_strategy);
            b.set_member_name ("singbox_domain_strategy"); b.add_string_value (singbox_domain_strategy);
            b.set_member_name ("rules");
            b.begin_array ();
            for (uint i = 0; i < rules.get_n_items (); i++) {
                ((RoutingRule) rules.get_item (i)).to_json (b);
            }
            b.end_array ();
            b.end_object ();
        }
    }
}
