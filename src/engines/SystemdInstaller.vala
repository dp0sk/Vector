using Vector.Services;
namespace Vector.Engines {

    // Privileged TUN plumbing: vector-tun.service with pinned router core.
    // One pkexec prompt to rule them all. Everything else (engines, proxy-mode,
    // session router) runs strictly unprivileged as user, don't run those as root!
    public class SystemdInstaller : GLib.Object {

        // bump when service layout breaks compatibility
        // v2: pinned sing-box router (vector-router) + unprivileged user engines
        public const int ROUTER_API = 2;

        public const string UNIT_FILE = "/etc/systemd/system/vector-tun.service";
        private const string POLKIT_RULE_FILE = "/etc/polkit-1/rules.d/49-vector.rules";

        // router cores we allow for TUN. Remember to update ConfigGenerator.gen_router_for
        // and router_exec_args if you add something new here!
        public const string[] ROUTER_CORES = { "sing-box" };

        // obsolete SELinux modules from earlier versions:
        // Fedora no longer needs them, remove on install/uninstall if present
        private const string[] OLD_SELINUX_MODULES = { "vector_tun" };
        private const string[] OLD_SELINUX_AUDIT_MODULES = { "my-vector-router", "my-singbox" };

        public static int installed_api () {
            string? content = read_file (Paths.ROUTER_API_FILE);
            return content != null ? int.parse (content.strip ()) : 0;
        }

        public static string installed_router_core () {
            string? content = read_file (Paths.ROUTER_CORE_FILE);
            if (content != null && content.strip () != "") return content.strip ();
            return "sing-box";
        }

        // check against build-time baked version, NOT whatever random binary is sitting on disk!
        // Otherwise reinstalling with a stale binary in cache would falsely pass.
        public static bool router_version_current () {
            if (Config.SING_BOX_VERSION == "") return true; // un-pinned build
            string? installed = read_file (Paths.ROUTER_VERSION_FILE);
            return installed != null && version_token_present (installed, Config.SING_BOX_VERSION);
        }

        // exact token match so 1.14.4 doesn't match 1.14.40 or 1.14.4-lx.33
        private static bool version_token_present (string line, string version) {
            foreach (var token in line.strip ().split (" ")) {
                if (token == version) return true;
            }
            return false;
        }

        private static string? core_version_line (string bin) {
            if (!GLib.FileUtils.test (bin, GLib.FileTest.IS_EXECUTABLE)) return null;
            try {
                var proc = new GLib.Subprocess.newv ({ bin, "version" },
                    GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_MERGE);
                string out_str;
                proc.communicate_utf8 (null, null, out out_str, null);
                if (!proc.get_if_exited () || proc.get_exit_status () != 0) return null;
                foreach (var line in out_str.split ("\n")) {
                    string l = line.strip ();
                    if (l != "") return l;
                }
            } catch (GLib.Error e) {}
            return null;
        }

        // test instances (VECTOR_UNIT_SUFFIX) must never touch the real system service
        public static bool service_present () {
            if (is_test_instance ()) return false;
            return GLib.FileUtils.test (UNIT_FILE, GLib.FileTest.EXISTS);
        }

        // make sure unit file actually invokes current vector-router binary
        public static bool router_installed () {
            if (is_test_instance ()) return false;
            if (installed_api () != ROUTER_API) return false;
            if (!GLib.FileUtils.test (Paths.ROUTER_BIN, GLib.FileTest.IS_EXECUTABLE)) return false;
            string? unit = read_file (UNIT_FILE);
            return unit != null && unit.contains ("ExecStart=" + Paths.ROUTER_BIN + " ");
        }

        public static bool is_router_core (string core) {
            foreach (var c in ROUTER_CORES) if (c == core) return true;
            return false;
        }

        public static string? router_exec_args (string core) {
            switch (core) {
                case "sing-box": return "run -c " + GLib.Shell.quote (Paths.router_json ());
                default:         return null;
            }
        }

        // one pkexec prompt to setup pinned binary, systemd unit and polkit rule
        public async void install (string router_core) throws GLib.Error {
            if (is_test_instance ()) {
                throw new GLib.IOError.PERMISSION_DENIED ("not installing the system service from a test instance (VECTOR_UNIT_SUFFIX)");
            }
            string? exec_args = router_exec_args (router_core);
            if (!is_router_core (router_core) || exec_args == null) {
                throw new GLib.IOError.NOT_SUPPORTED ("'%s' cannot be used as the TUN router".printf (router_core));
            }
            string? router_binary = Paths.find_core (router_core);
            if (router_binary == null) throw core_not_found (router_core);
            string? router_version = core_version_line (router_binary);
            if (router_version == null) {
                throw new GLib.IOError.FAILED ("could not determine the %s version to install".printf (router_core));
            }
            // refuse mismatched core: if user has a stale binary lying around,
            // sing-box will choke with "unknown field" on newer config options
            if (Config.SING_BOX_VERSION != "" && !version_token_present (router_version, Config.SING_BOX_VERSION)) {
                throw new GLib.IOError.FAILED (
                    "found %s at %s, but this build expects sing-box %s — the bundled core is missing; install the full package".printf (
                        router_version, router_binary, Config.SING_BOX_VERSION));
            }
            copy_engine_cores ();

            // root under pkexec might fail to read user home files, stage in world-readable /tmp
            var stage = new StageDir ();
            try {
                string username = GLib.Environment.get_user_name ();
                stage.copy_executable (router_binary, "vector-router");
                stage.write ("ROUTER_API", "%d\n".printf (ROUTER_API));
                stage.write ("ROUTER_CORE", router_core + "\n");
                stage.write ("ROUTER_VERSION", router_version + "\n");
                stage.write ("vector-tun.service", unit_text (router_core, exec_args, username));
                stage.write ("49-vector.rules", polkit_rule (username));
                yield run_as_root (install_script (stage));
            } finally {
                stage.remove ();
            }
        }

        // copy cores to ~/.local/share/vector/bin before install script wipes old system copies
        private static void copy_engine_cores () throws GLib.Error {
            var stager = new UserUnit (Paths.engine_unit (), "engine", Paths.engine_log (), false);
            foreach (var core in new string[] { Cores.SING_BOX, Cores.XRAY }) {
                if (stager.stable_binary (core) == null) throw core_not_found (core);
            }
        }

        private static string unit_text (string router_core, string exec_args, string username) {
            string log = Paths.router_log ();
            return
                "[Unit]\n" +
                "Description=Vector TUN router (pinned %s)\n".printf (router_core) +
                "After=network-online.target\n" +
                "Wants=network-online.target\n\n" +
                "[Service]\n" +
                "Type=exec\n" +
                "User=%s\n".printf (username) +
                "ExecStart=%s %s\n".printf (Paths.ROUTER_BIN, exec_args) +
                "ExecReload=/bin/kill -HUP $MAINPID\n" +
                "Restart=on-failure\n" +
                "RestartSec=2\n" +
                "NoNewPrivileges=yes\n" +
                "PrivateTmp=yes\n" +
                "ProtectSystem=strict\n" +
                "ReadWritePaths=%s %s\n".printf (Paths.config_dir (), Paths.data_dir ()) +
                "AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE\n" +
                "CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE\n" +
                "StandardOutput=truncate:%s\n".printf (log) +
                "StandardError=truncate:%s\n".printf (log);
        }

        private static string polkit_rule (string username) {
            return
                "polkit.addRule(function(action, subject) {\n" +
                "  if (action.id == \"org.freedesktop.systemd1.manage-units\" &&\n" +
                "      subject.user == \"%s\" &&\n".printf (username) +
                "      action.lookup(\"unit\") == \"vector-tun.service\") {\n" +
                "    return polkit.Result.YES;\n" +
                "  }\n" +
                "});\n";
        }

        private static string install_script (StageDir stage) {
            string q_dir = GLib.Shell.quote (GLib.Path.get_dirname (Paths.ROUTER_BIN));
            string q_router = GLib.Shell.quote (Paths.ROUTER_BIN);
            return
                "set -e\n" +
                stop_service_script () +
                "modprobe tun 2>/dev/null || true\n" +
                "mkdir -p /etc/modules-load.d\n" +
                "printf 'tun\\n' > /etc/modules-load.d/tun.conf\n" +
                "rm -rf %s\n".printf (q_dir) +
                "mkdir -p %s\n".printf (q_dir) +
                "install -m 755 %s %s\n".printf (stage.quoted ("vector-router"), q_router) +
                "install -m 644 %s %s\n".printf (stage.quoted ("ROUTER_API"), GLib.Shell.quote (Paths.ROUTER_API_FILE)) +
                "install -m 644 %s %s\n".printf (stage.quoted ("ROUTER_CORE"), GLib.Shell.quote (Paths.ROUTER_CORE_FILE)) +
                "install -m 644 %s %s\n".printf (stage.quoted ("ROUTER_VERSION"), GLib.Shell.quote (Paths.ROUTER_VERSION_FILE)) +
                "install -m 644 %s %s\n".printf (stage.quoted ("vector-tun.service"), UNIT_FILE) +
                "mkdir -p %s\n".printf (GLib.Path.get_dirname (POLKIT_RULE_FILE)) +
                "install -m 644 %s %s\n".printf (stage.quoted ("49-vector.rules"), POLKIT_RULE_FILE) +
                "systemctl daemon-reload\n" +
                // fix SELinux context under /usr/local/libexec or systemd will deny exec
                "if command -v restorecon >/dev/null 2>&1; then\n" +
                "  restorecon -F %s 2>/dev/null || true\n".printf (q_router) +
                "fi\n" +
                remove_old_selinux_modules_script ();
        }

        public async void uninstall () throws GLib.Error {
            if (is_test_instance ()) {
                throw new GLib.IOError.PERMISSION_DENIED ("not touching the system service from a test instance (VECTOR_UNIT_SUFFIX)");
            }
            yield run_as_root (uninstall_script ());
        }

        private static string uninstall_script () {
            return
                "set -e\n" +
                stop_service_script () +
                "rm -f %s %s\n".printf (UNIT_FILE, POLKIT_RULE_FILE) +
                "rm -rf %s\n".printf (GLib.Shell.quote (GLib.Path.get_dirname (Paths.ROUTER_BIN))) +
                "systemctl daemon-reload\n" +
                remove_old_selinux_modules_script ();
        }

        private static bool is_test_instance () {
            return Paths.unit_suffix () != "";
        }

        // semodule -r fails if any module in list is missing, so remove individually
        private static string remove_old_selinux_modules_script () {
            string script = "if command -v semodule >/dev/null 2>&1; then\n";
            foreach (var m in OLD_SELINUX_MODULES) script += "  semodule -r %s 2>/dev/null || true\n".printf (m);
            foreach (var m in OLD_SELINUX_AUDIT_MODULES) script += "  semodule -X 300 -r %s 2>/dev/null || true\n".printf (m);
            return script + "fi\n";
        }

        private static string stop_service_script () {
            return
                "systemctl stop vector-tun.service 2>/dev/null || true\n" +
                "systemctl disable vector-tun.service 2>/dev/null || true\n";
        }

        private static GLib.Error core_not_found (string core) {
            return new GLib.IOError.NOT_FOUND (
                "%s binary not found (searched: %s)".printf (core, Paths.search_description ()));
        }

        private static string? read_file (string path) {
            try {
                string content;
                GLib.FileUtils.get_contents (path, out content);
                return content;
            } catch (GLib.Error e) {
                return null;
            }
        }

        private static async void run_as_root (string script) throws GLib.Error {
            var proc = new GLib.Subprocess.newv ({ "pkexec", "sh", "-c", script }, GLib.SubprocessFlags.NONE);
            yield proc.wait_async (null);
            int status = proc.get_if_exited () ? proc.get_exit_status () : -1;
            switch (status) {
                case 0:
                    return;
                // pkexec: 126 user cancelled prompt, 127 auth failed
                case 126:
                case 127:
                    throw new GLib.IOError.PERMISSION_DENIED ("authentication was cancelled or failed");
                default:
                    throw new GLib.IOError.FAILED ("the privileged script failed (exit status %d)".printf (status));
            }
        }

        private class StageDir : GLib.Object {
            private string dir;
            private string[] names = {};

            public StageDir () throws GLib.Error {
                try {
                    dir = GLib.DirUtils.make_tmp ("vector-stage-XXXXXX");
                    GLib.FileUtils.chmod (dir, 0755);
                } catch (GLib.Error e) {
                    throw new GLib.IOError.FAILED ("Failed to create temporary staging directory: %s".printf (e.message));
                }
            }

            public string path (string name) {
                return GLib.Path.build_filename (dir, name);
            }

            public string quoted (string name) {
                return GLib.Shell.quote (path (name));
            }

            public void write (string name, string content) throws GLib.Error {
                names += name;
                GLib.FileUtils.set_contents (path (name), content);
            }

            public void copy_executable (string source, string name) throws GLib.Error {
                names += name;
                try {
                    var dst = GLib.File.new_for_path (path (name));
                    GLib.File.new_for_path (source).copy (dst, GLib.FileCopyFlags.OVERWRITE, null, null);
                    dst.set_attribute_uint32 (GLib.FileAttribute.UNIX_MODE, 0755, GLib.FileQueryInfoFlags.NONE, null);
                } catch (GLib.Error e) {
                    throw new GLib.IOError.FAILED ("Failed to stage %s in %s: %s".printf (source, dir, e.message));
                }
            }

            public void remove () {
                foreach (var name in names) GLib.FileUtils.unlink (path (name));
                GLib.DirUtils.remove (dir);
            }
        }
    }
}
