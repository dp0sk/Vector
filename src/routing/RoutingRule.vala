using Vector.Services;
namespace Vector.Routing {

    public class RoutingRule : GLib.Object {
        public string id;
        public string remarks;
        public bool enabled = true;
        public string outbound_tag; // "proxy", "direct", "block"
        public string network;      // "", "tcp", "udp"
        public string port;         // e.g. "0-65535" or "80,443"
        public string inbound_tag;  // e.g. "tun", "socks"
        public string protocol;     // e.g. "http,tls,quic"
        public string domains;      // multiline or comma separated
        public string ips;          // multiline or comma separated
        public string processes;    // multiline or comma separated

        public RoutingRule (string remarks = "", string outbound_tag = "proxy") {
            this.id = GLib.Uuid.string_random ();
            this.remarks = remarks;
            this.outbound_tag = outbound_tag;
            this.network = "";
            this.port = "";
            this.inbound_tag = "";
            this.protocol = "";
            this.domains = "";
            this.ips = "";
            this.processes = "";
        }

        public static RoutingRule from_json (Json.Object o) {
            var rule = new RoutingRule ();
            rule.id = Util.j_str (o, "id");
            if (rule.id == "") rule.id = GLib.Uuid.string_random ();
            rule.remarks = Util.j_str (o, "remarks");
            rule.enabled = o.has_member ("enabled") ? Util.j_bool (o, "enabled") : true;
            rule.outbound_tag = Util.j_str (o, "outboundTag");
            if (rule.outbound_tag == "") rule.outbound_tag = "proxy";
            rule.network = Util.j_str (o, "network");
            rule.port = Util.j_str (o, "port");
            rule.inbound_tag = Util.j_str (o, "inboundTag");
            rule.protocol = Util.j_str (o, "protocol");
            rule.domains = Util.j_str (o, "domains");
            rule.ips = Util.j_str (o, "ips");
            rule.processes = Util.j_str (o, "processes");
            return rule;
        }

        public void to_json (Json.Builder b) {
            b.begin_object ();
            b.set_member_name ("id");           b.add_string_value (id);
            b.set_member_name ("remarks");      b.add_string_value (remarks);
            b.set_member_name ("enabled");      b.add_boolean_value (enabled);
            b.set_member_name ("outboundTag");  b.add_string_value (outbound_tag);
            b.set_member_name ("network");      b.add_string_value (network);
            b.set_member_name ("port");         b.add_string_value (port);
            b.set_member_name ("inboundTag");   b.add_string_value (inbound_tag);
            b.set_member_name ("protocol");     b.add_string_value (protocol);
            b.set_member_name ("domains");      b.add_string_value (domains);
            b.set_member_name ("ips");          b.add_string_value (ips);
            b.set_member_name ("processes");    b.add_string_value (processes);
            b.end_object ();
        }
    }
}
