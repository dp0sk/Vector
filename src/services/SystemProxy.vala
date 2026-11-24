using Vector.Models;
namespace Vector.Services {

    // GNOME and most desktops use gsettings org.gnome.system.proxy.
    // KDE uses kioslaverc via kwriteconfig.
    // Run async to avoid blocking the UI thread.
    public class SystemProxy : GLib.Object {

        private const string SCHEMA = "org.gnome.system.proxy";
        private const string[] PROTOCOLS = { "http", "https", "ftp", "socks" };

        private static GLib.Settings? open_schema (string id) {
            var src = GLib.SettingsSchemaSource.get_default ();
            if (src == null || src.lookup (id, true) == null) return null;
            return new GLib.Settings (id);
        }

        private static bool is_kde () {
            string desktop = GLib.Environment.get_variable ("XDG_CURRENT_DESKTOP") ?? "";
            return desktop.contains ("KDE");
        }

        // desktop proxy bypass list: loopback, lan subnets, and explicit ips/domains.
        // can't put geosite/geoip rules here, desktop schemas only understand plain ips and domain globs
        public static string[] ignore_hosts_for (AppSettings s) {
            string[] hosts = { "localhost", "127.0.0.0/8", "::1" };
            if (s.bypass_lan) {
                foreach (var c in new string[] { "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                                 "169.254.0.0/16", "fc00::/7", "fe80::/10" }) hosts += c;
            }
            foreach (var item in Util.split_list (s.bypass_ips)) {
                if (item.contains ("/") || GLib.Hostname.is_ip_address (item)) hosts += item;
            }
            foreach (var item in Util.split_list (s.bypass_domains)) {
                string d = item;
                if (d.has_prefix ("domain:")) d = d.substring (7);
                else if (d.has_prefix ("full:")) { hosts += d.substring (5); continue; }
                else if (d.has_prefix (".")) d = d.substring (1);
                if (d.contains (":") || !d.contains (".")) continue; // skip geosite:, keywords, bare hostnames
                hosts += d;
                hosts += "*." + d;
            }
            return hosts;
        }

        public static void apply (AppSettings s) {
            int port = s.current_mixed_port;
            string[] ignore = ignore_hosts_for (s);
            var proxy = open_schema (SCHEMA);
            if (proxy != null) {
                foreach (var proto in PROTOCOLS) {
                    var child = open_schema (SCHEMA + "." + proto);
                    if (child == null) continue;
                    child.set_string ("host", "127.0.0.1");
                    child.set_int ("port", port);
                }
                proxy.set_strv ("ignore-hosts", ignore);
                proxy.set_string ("mode", "manual");
            }
            if (is_kde ()) {
                string http = "http://127.0.0.1:%d".printf (port);
                kde_write ({
                    "ProxyType", "1", "httpProxy", http, "httpsProxy", http, "ftpProxy", http,
                    "socksProxy", "socks://127.0.0.1:%d".printf (port),
                    "NoProxyFor", string.joinv (",", ignore)
                });
            }
            if (proxy == null && !is_kde ()) warning ("No supported desktop proxy settings found.");
            GLib.Settings.sync (); // force flush to dconf now or settings get lost if process exits immediately
        }

        public static void clear () {
            var proxy = open_schema (SCHEMA);
            if (proxy != null) proxy.set_string ("mode", "none");
            if (is_kde ()) kde_write ({ "ProxyType", "0" });
            GLib.Settings.sync ();
        }

        // KDE quirk: write directly into kioslaverc config and kick KIO via dbus to reload
        private static void kde_write (string[] kv) {
            string tool = GLib.Environment.get_variable ("KDE_SESSION_VERSION") == "6" ? "kwriteconfig6" : "kwriteconfig5";
            var cmd = new GLib.StringBuilder ();
            for (int i = 0; i + 1 < kv.length; i += 2) {
                cmd.append ("%s --file kioslaverc --group 'Proxy Settings' --key %s %s; ".printf (
                    tool, GLib.Shell.quote (kv[i]), GLib.Shell.quote (kv[i + 1])));
            }
            cmd.append ("dbus-send --type=signal /KIO/Scheduler org.kde.KIO.Scheduler.reparseSlaveConfiguration string:''");
            try {
                new GLib.Subprocess.newv ({ "/bin/sh", "-c", cmd.str },
                    GLib.SubprocessFlags.STDOUT_SILENCE | GLib.SubprocessFlags.STDERR_SILENCE);
            } catch (GLib.Error e) {
                warning ("KDE proxy update failed: %s", e.message);
            }
        }
    }
}
