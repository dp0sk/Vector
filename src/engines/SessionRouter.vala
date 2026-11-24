using Vector.Services;
using Vector.Testing;
namespace Vector.Engines {

    // Per-session TUN mode without installing system service (one password prompt per session):
    //
    //   systemd-run --user --scope
    //     sh -c 'pkexec "$@"; exit $?'
    //       pkexec setpriv --reuid=<user> ... --pdeathsig=TERM -- sing-box run -c router.json
    //
    // setpriv drops root back to user but keeps CAP_NET_ADMIN.
    // This allows reloading (SIGHUP) and stopping router without sudo.
    // When turning TUN off, reload with empty config instead of stopping to avoid new prompt.
    //
    // pam_systemd moves pkexec out of user scope, so we track PID manually.
    // sh stays in user scope; on logout systemd kills sh, and setpriv kills router via pdeathsig.
    public class SessionRouter : GLib.Object {

        public const string CAPS = "+net_admin,+net_raw,+net_bind_service";

        public signal void log_line (string line);
        // The router process this app started has exited.
        public signal void exited ();

        private GLib.Subprocess? proc = null;

        // Empty if usable, else the missing program.
        public static string missing_tool () {
            foreach (var t in new string[] { "pkexec", "setpriv", "systemd-run" }) {
                if (GLib.Environment.find_program_in_path (t) == null) return t;
            }
            return "";
        }

        public static string mode () {
            try {
                string m;
                GLib.FileUtils.get_contents (Paths.session_router_mode_file (), out m);
                return m.strip ();
            } catch (GLib.Error e) {
                return "";
            }
        }

        private static void set_mode (string m) {
            try { GLib.FileUtils.set_contents (Paths.session_router_mode_file (), m + "\n"); }
            catch (GLib.Error e) {}
        }

        public async bool is_alive () {
            return router_pid () > 0;
        }

        // The running router's PID from the PID file, or 0. The process must
        // still be ours and run router.json: a PID can be reused.
        private static int router_pid () {
            try {
                string text;
                GLib.FileUtils.get_contents (Paths.session_router_pid_file (), out text);
                int pid = int.parse (text.strip ());
                return pid > 0 && is_router_process (pid) ? pid : 0;
            } catch (GLib.Error e) {
                return 0;
            }
        }

        private static bool is_router_process (int pid) {
            string proc_dir = "/proc/%d".printf (pid);
            // The real UID from status: /proc/<pid> itself may be root's, as
            // the process went through pkexec and holds capabilities.
            if (proc_uid (proc_dir) != (int) Posix.getuid ()) return false;
            try {
                uint8[] raw;
                GLib.FileUtils.get_data (proc_dir + "/cmdline", out raw);
                // NUL-separated argv: look for "run", "-c", router.json.
                string[] args = {};
                int start = 0;
                for (int i = 0; i < raw.length; i++) {
                    if (raw[i] != 0) continue;
                    args += Util.bytes_to_string (new GLib.Bytes (raw[start:i]));
                    start = i + 1;
                }
                for (int i = 0; i + 2 < args.length; i++) {
                    if (args[i] == "run" && args[i + 1] == "-c" && args[i + 2] == Paths.router_json ()) return true;
                }
            } catch (GLib.Error e) {}
            return false;
        }

        // The router process among the children of `parent` (the sh), or 0.
        private static int router_child_of (int parent) {
            try {
                string children;
                GLib.FileUtils.get_contents ("/proc/%d/task/%d/children".printf (parent, parent), out children);
                foreach (var part in children.split (" ")) {
                    int pid = int.parse (part.strip ());
                    if (pid > 0 && is_router_process (pid)) return pid;
                }
            } catch (GLib.Error e) {}
            return 0;
        }

        private static int proc_uid (string proc_dir) {
            try {
                string status;
                GLib.FileUtils.get_contents (proc_dir + "/status", out status);
                foreach (var line in status.split ("\n")) {
                    if (line.has_prefix ("Uid:")) return int.parse (line.substring (4).strip ().split ("\t")[0]);
                }
            } catch (GLib.Error e) {}
            return -1;
        }

        private static void set_pid (int pid) {
            try {
                if (pid > 0) GLib.FileUtils.set_contents (Paths.session_router_pid_file (), "%d\n".printf (pid));
                else GLib.FileUtils.unlink (Paths.session_router_pid_file ());
            } catch (GLib.Error e) {}
        }

        // Starts the router with `cfg` (a TUN config) and waits until it
        // listens on `port`, allowing time for the password dialog. Returns an
        // error message, or null on success.
        public async string? start (string bin, string cfg, int port) {
            if (router_pid () > 0) yield stop ();
            // check port before password prompt so user doesn't waste time if port is busy
            if (!(yield Tester.wait_port_free ((uint16) port))) return Tester.port_taken_message ((uint16) port);
            string setpriv = GLib.Environment.find_program_in_path ("setpriv");
            string user = GLib.Environment.get_user_name ();
            string[] argv = {
                "systemd-run", "--user", "--scope", "--quiet", "--collect",
                "--unit=" + Paths.session_router_unit (),
                "--description=Vector TUN router (this session)",
                // "; exit $?" prevents sh from replacing itself with pkexec (sh must stay parent)
                "sh", "-c", "pkexec \"$@\"; exit $?", "sh", setpriv,
                "--reuid=" + user, "--regid=" + ((int) Posix.getgid ()).to_string (), "--init-groups",
                "--inh-caps=" + CAPS, "--ambient-caps=" + CAPS, "--pdeathsig=TERM",
                "--", bin, "run", "-c", cfg
            };
            try {
                var launcher = new GLib.SubprocessLauncher (GLib.SubprocessFlags.NONE);
                launcher.set_stdout_file_path (Paths.session_router_log ());
                launcher.set_stderr_file_path (Paths.session_router_log ());
                proc = launcher.spawnv (argv);
            } catch (GLib.Error e) {
                return e.message;
            }
            var p = proc;
            int sh_pid = int.parse (p.get_identifier () ?? "0");
            bool done = false;
            p.wait_async.begin (null, (obj, res) => {
                try { p.wait_async.end (res); } catch (GLib.Error e) {}
                done = true;
                if (proc == p) {
                    proc = null;
                    set_mode ("");
                    set_pid (0);
                    exited ();
                }
            });
            // wait up to 3 minutes for password entry
            for (int i = 0; i < 1800; i++) {
                if (done) {
                    int st = p.get_if_exited () ? p.get_exit_status () : -1;
                    // pkexec: 126 = dialog dismissed, 127 = not authorized.
                    if (st == 126 || st == 127) return "authentication was cancelled or failed";
                    return "the router exited (status %d) — see %s".printf (st, Paths.session_router_log ());
                }
                int pid = 0;
                if (Tester.port_open_sync ((uint16) port) && (pid = router_child_of (sh_pid)) > 0) {
                    set_pid (pid);
                    set_mode ("tun");
                    log_line ("[router] session router is up (TUN, until logout).");
                    return null;
                }
                yield Util.sleep_ms (100);
            }
            yield stop ();
            return "the router did not start in time";
        }

        public async bool reload (string new_mode) {
            int pid = router_pid ();
            if (pid <= 0 || Posix.kill (pid, Posix.Signal.HUP) != 0) {
                log_line ("[router] session router reload failed: the router is not running.");
                return false;
            }
            set_mode (new_mode);
            return true;
        }

        // send SIGTERM first, fallback to SIGKILL after 3 seconds
        public async void stop () {
            proc = null;
            int pid = router_pid ();
            if (pid > 0) {
                Posix.kill (pid, Posix.Signal.TERM);
                for (int i = 0; i < 30 && is_router_process (pid); i++) yield Util.sleep_ms (100);
                if (is_router_process (pid)) Posix.kill (pid, Posix.Signal.KILL);
            }
            // The scope, where pam_systemd left the router in it.
            string o;
            yield Util.run_command ({ "systemctl", "--user", "stop", Paths.session_router_unit () }, out o);
            set_pid (0);
            set_mode ("");
        }
    }
}
