namespace Vector.Models {

    // wg / amnezia config bag so Node doesn't get bloated with a dozen loose fields.
    // awg holds junk params (Jc, S1, etc) normalized to lowercase like awg-quick spits out
    public class WgConfig : GLib.Object {

        public string private_key = "";
        public string peer_public_key = "";
        public string preshared_key = "";
        public string local_address = "";   // CIDRs from [Interface] Address
        public string allowed_ips = "";
        public string dns = "";             // [Interface] DNS, only kept around for re-export
        public int mtu = 0;
        public string keepalive = "";       // secs, or cursed "min-max" range string in AmneziaWG 3.x; "" = off
        public GLib.HashTable<string, string> awg = new GLib.HashTable<string, string> (str_hash, str_equal);

        public WgConfig copy () {
            var c = new WgConfig ();
            c.private_key = private_key;
            c.peer_public_key = peer_public_key;
            c.preshared_key = preshared_key;
            c.local_address = local_address;
            c.allowed_ips = allowed_ips;
            c.dns = dns;
            c.mtu = mtu;
            c.keepalive = keepalive;
            awg.foreach ((k, v) => { c.awg.insert (k, v); });
            return c;
        }
    }
}
