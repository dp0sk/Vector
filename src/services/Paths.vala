namespace Vector.Services {

    public class Paths : GLib.Object {

        public static string config_dir () {
            return GLib.Path.build_filename (GLib.Environment.get_user_config_dir (), "vector");
        }

        public static string data_dir () {
            return GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "vector");
        }

        public static string user_bin_dir () {
            return GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "vector", "bin");
        }

        // temp dir for configs with plaintext creds: stick it in XDG_RUNTIME_DIR (tmpfs in RAM), fall back to data dir
        public static string runtime_dir () {
            string? rt = GLib.Environment.get_variable ("XDG_RUNTIME_DIR");
            string dir = (rt != null && rt != "")
                ? GLib.Path.build_filename (rt, "vector")
                : GLib.Path.build_filename (data_dir (), "run");
            GLib.DirUtils.create_with_parents (dir, 0700);
            return dir;
        }

        // configs and data have passwords and subscription tokens, lock down permissions so others can't read them
        public static void ensure () {
            GLib.DirUtils.create_with_parents (config_dir (), 0700);
            GLib.DirUtils.create_with_parents (data_dir (), 0700);
            GLib.DirUtils.create_with_parents (user_bin_dir (), 0755);
            GLib.FileUtils.chmod (config_dir (), 0700);
            GLib.FileUtils.chmod (data_dir (), 0700);
            try {
                var dir = GLib.Dir.open (config_dir ());
                string? name;
                while ((name = dir.read_name ()) != null) {
                    string p = GLib.Path.build_filename (config_dir (), name);
                    if (GLib.FileUtils.test (p, GLib.FileTest.IS_REGULAR)) GLib.FileUtils.chmod (p, 0600);
                }
            } catch (GLib.FileError e) {}
        }

        public static string settings_json ()     { return in_config ("settings.json"); }
        public static string nodes_json ()        { return in_config ("nodes.json"); }
        public static string subs_json ()         { return in_config ("subs.json"); }
        public static string routing_json ()      { return in_config ("routing.json"); }
        public static string router_json ()       { return in_config ("router.json"); }
        public static string proxy_router_json () { return in_config ("proxy-router.json"); }
        public static string engine_json ()       { return in_config ("engine.json"); }

        // system service log gets owned by root, user-run routers need their own logs
        public static string router_log ()         { return in_data ("router.log"); }
        public static string proxy_router_log ()   { return in_data ("proxy-router.log"); }
        public static string session_router_log () { return in_data ("session-router.log"); }
        public static string engine_log ()         { return in_data ("engine.log"); }

        // PID of the per-session router (SessionRouter), for the app restarted
        // later in the session.
        public static string session_router_pid_file () {
            return GLib.Path.build_filename (runtime_dir (), "session-router-pid" + unit_suffix ());
        }

        public static string session_router_mode_file () {
            return GLib.Path.build_filename (runtime_dir (), "session-router-mode" + unit_suffix ());
        }

        private static string in_config (string name) { return GLib.Path.build_filename (config_dir (), name); }
        private static string in_data (string name)   { return GLib.Path.build_filename (data_dir (), name); }

        // suffix from env var to run test instance without affecting installed units
        public static string unit_suffix () {
            string? s = GLib.Environment.get_variable ("VECTOR_UNIT_SUFFIX");
            if (s == null || s == "") return "";
            var sb = new GLib.StringBuilder ("-");
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if (c.isalnum () || c == '-') sb.append_c (c);
            }
            return sb.str;
        }

        public static string tun_unit ()            { return "vector-tun%s.service".printf (unit_suffix ()); }
        public static string engine_unit ()         { return "vector-engine%s.service".printf (unit_suffix ()); }
        public static string proxy_router_unit ()   { return "vector-proxy%s.service".printf (unit_suffix ()); }
        public static string session_router_unit () { return "vector-tun-session%s.scope".printf (unit_suffix ()); }

        public const string ROUTER_BIN = "/usr/local/libexec/vector/vector-router";
        public const string ROUTER_API_FILE = "/usr/local/libexec/vector/ROUTER_API";
        public const string ROUTER_CORE_FILE = "/usr/local/libexec/vector/ROUTER_CORE";
        // check installed router version against bundled binary so config syntax breaking changes don't blow up
        public const string ROUTER_VERSION_FILE = "/usr/local/libexec/vector/ROUTER_VERSION";

        public static string? find_core (string name) {
            foreach (var dir in core_dirs ()) {
                string path = GLib.Path.build_filename (dir, name);
                if (GLib.FileUtils.test (path, GLib.FileTest.IS_EXECUTABLE)
                    && !GLib.FileUtils.test (path, GLib.FileTest.IS_DIR)) {
                    return path;
                }
            }
            return GLib.Environment.find_program_in_path (name);
        }

        public static string search_description () {
            return string.joinv (", ", core_dirs ()) + ", $PATH";
        }

        // search order: current exe dir, libexec, appimage bundle, user bin, system paths. keep old v2ray-vala path for backwards compat
        private static string[] core_dirs () {
            string[] dirs = {};
            try {
                string exe_dir = GLib.Path.get_dirname (GLib.FileUtils.read_link ("/proc/self/exe"));
                dirs += exe_dir;
                dirs += GLib.Path.build_filename (exe_dir, "..", "libexec", "vector");
            } catch (GLib.FileError e) {
            }
            string? appdir = GLib.Environment.get_variable ("APPDIR");
            if (appdir != null) dirs += GLib.Path.build_filename (appdir, "usr", "libexec", "vector");
            dirs += user_bin_dir ();
            dirs += Config.LIBEXECDIR;
            dirs += "/usr/libexec/vector";
            dirs += "/usr/local/libexec/vector";
            dirs += "/usr/libexec/v2ray-vala";
            dirs += "/usr/local/libexec/v2ray-vala";
            return dirs;
        }
    }
}
