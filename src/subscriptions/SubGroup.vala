using Vector.Services;
namespace Vector.Subs {

    // group of sub URLs fetched together. manual nodes get tied by name string instead of url
    public class SubGroup : GLib.Object {
        public string name;
        public Gtk.StringList urls = new Gtk.StringList (null);
        public bool enable_update = false;
        public int update_interval = 0;     // mins
        public string user_agent = "";
        // custom headers: "Key: val; Other: val"
        public string headers = "";
        public int64 last_update_time = 0;

        public SubGroup (string name) {
            this.name = name;
        }

        public static SubGroup from_json (Json.Object o) {
            var g = new SubGroup (Util.j_str (o, "name"));
            g.enable_update = Util.j_bool (o, "enable_update");
            g.update_interval = Util.j_int (o, "update_interval");
            g.user_agent = Util.j_str (o, "user_agent");
            g.headers = Util.j_str (o, "xhttp_tags"); // legacy key name from when this was only used for xhttp
            if (o.has_member ("last_update_time")) g.last_update_time = o.get_int_member ("last_update_time");
            if (o.has_member ("urls")) {
                o.get_array_member ("urls").foreach_element ((arr, i, el) => {
                    if (el.get_node_type () == Json.NodeType.VALUE) g.urls.append (el.get_string ());
                });
            }
            return g;
        }

        public void to_json (Json.Builder b) {
            b.begin_object ();
            b.set_member_name ("name");              b.add_string_value (name);
            b.set_member_name ("enable_update");     b.add_boolean_value (enable_update);
            b.set_member_name ("update_interval");   b.add_int_value (update_interval);
            b.set_member_name ("user_agent");        b.add_string_value (user_agent);
            b.set_member_name ("xhttp_tags");        b.add_string_value (headers);
            b.set_member_name ("last_update_time");  b.add_int_value (last_update_time);
            b.set_member_name ("urls");
            b.begin_array ();
            for (uint i = 0; i < urls.get_n_items (); i++) b.add_string_value (urls.get_string (i));
            b.end_array ();
            b.end_object ();
        }
    }
}
