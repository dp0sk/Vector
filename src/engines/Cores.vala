using Vector.Models;
namespace Vector.Engines {

    public class Cores : GLib.Object {

        public const string SING_BOX = "sing-box";
        public const string XRAY = "xray";
        // sing-box fork with AmneziaWG support; CLI and config format is identical
        public const string SING_BOX_LX = "sing-box-lx";

        public const string[] ALL = { SING_BOX, XRAY, SING_BOX_LX };

        // xhttp is a transport, but shown in protocol list because only xray supports it
        public const string[] PROTOCOL_KEYS = {
            "vless", "vmess", "trojan", "shadowsocks", "socks", "http", "wireguard", "hysteria2", "tuic", "awg", "xhttp"
        };

        public static string label_for_key (string key) {
            switch (key) {
                case "vless":       return "VLESS";
                case "vmess":       return "VMess";
                case "trojan":      return "Trojan";
                case "shadowsocks": return "Shadowsocks";
                case "socks":       return "SOCKS";
                case "http":        return "HTTP";
                case "xhttp":       return "XHTTP transport";
                case "xray-json":   return "Xray config";
                case "wireguard":   return "WireGuard";
                case "awg":         return "AmneziaWG";
                case "hysteria2":   return "Hysteria 2";
                case "tuic":        return "TUIC";
                default:            return key;
            }
        }

        public static string[] cores_for_key (string key) {
            switch (key) {
                case "awg":       return { SING_BOX_LX };
                case "wireguard": return { SING_BOX, SING_BOX_LX };
                case "hysteria2":
                case "tuic":      return { SING_BOX, SING_BOX_LX };
                case "xhttp":     return { XRAY };
                case "xray-json": return { XRAY };
                default:          return { SING_BOX, XRAY, SING_BOX_LX };
            }
        }

        public static string key_for (Models.Node n) {
            if (n.is_xray_json ()) return "xray-json";
            if (n.is_wireguard ()) return n.protocol;
            if (n.network == "xhttp" || n.network == "splithttp") return "xhttp";
            return n.protocol;
        }

        private static bool contains (string[] list, string v) {
            foreach (var x in list) if (x == v) return true;
            return false;
        }

        public static string engine_core_for (Models.Node n, AppSettings s) {
            string key = key_for (n);
            string? pref = s.protocol_cores.lookup (key);
            if (pref != null && contains (cores_for_key (key), pref)) return pref;
            return default_core_for_key (key, s);
        }

        public static string default_core_for_key (string key, AppSettings s) {
            string[] allowed = cores_for_key (key);
            return contains (allowed, s.core) ? s.core : allowed[0];
        }

        // xray uses its own config format; sing-box and sing-box-lx share the same schema
        public static bool uses_xray_config (string core) {
            return core == XRAY;
        }
    }
}
