using Vector.Services;
using Vector.Testing;
namespace Vector.Engines {

    // run engine via systemd-run --user so it keeps running when window is closed.
    // fallback to child process if user systemd is unavailable
    public class UserUnit : GLib.Object {

        public string unit { get; construct; }
        public string label { get; construct; }    // log prefix: "engine", "router"
        public string log_path { get; construct; }
        public bool truncate_log { get; construct; }

        public signal void log_line (string line);

        private GLib.Subprocess? child = null;

        public UserUnit (string unit, string label, string log_path, bool truncate_log) {
            Object (unit: unit, label: label, log_path: log_path, truncate_log: truncate_log);
        }

        // don't run from AppImage mount: mount point vanishes on exit.
        // copy into ~/.local/share/vector/bin instead
        public string? stable_binary (string core) {
            string? src = Paths.find_core (core);
            if (src == null) return null;
            string dst = GLib.Path.build_filename (Paths.user_bin_dir (), core);
            if (src == dst) return dst;
            try {
                var sf = GLib.File.new_for_path (src);
                var df = GLib.File.new_for_path (dst);
                bool same = false;
                if (df.query_exists ()) {
                    var si = sf.query_info ("standard::size,time::modified", GLib.FileQueryInfoFlags.NONE);
                    var di = df.query_info ("standard::size,time::modified", GLib.FileQueryInfoFlags.NONE);
                    same = si.get_size () == di.get_size ()
                        && si.get_modification_date_time ().compare (di.get_modification_date_time ()) == 0;
                }
                if (!same) {
                    Paths.ensure ();
                    // write to .new and rename over: avoid ETXTBSY if binary is running
                    var tmp = GLib.File.new_for_path (dst + ".new");
                    sf.copy (tmp, GLib.FileCopyFlags.OVERWRITE | GLib.FileCopyFlags.ALL_METADATA, null, null);
                    GLib.FileUtils.chmod (dst + ".new", 0755);
                    tmp.move (df, GLib.FileCopyFlags.OVERWRITE, null, null);
                    log_line ("[%s] installed %s from %s".printf (label, dst, src));
                }
                return dst;
            } catch (GLib.Error e) {
                log_line ("[%s] could not copy %s to %s (%s); using it in place".printf (label, src, dst, e.message));
                return src;
            }
        }

        public async bool is_active () {
            if (child != null) return true;
            string o;
            return (yield Util.run_command ({ "systemctl", "--user", "is-active", unit }, out o)) == 0;
        }

        public async void stop () {
            if (child != null) {
                var c = child;
                child = null;
                yield Tester.kill_proc (c);
            }
            string o;
            yield Util.run_command ({ "systemctl", "--user", "stop", unit }, out o);
            yield Util.run_command ({ "systemctl", "--user", "reset-failed", unit }, out o);
        }

        // SIGHUP reloads sing-box config without closing sockets
        public async bool reload () {
            if (child != null) {
                child.send_signal (Posix.Signal.HUP);
                return true;
            }
            string o;
            int rc = yield Util.run_command ({ "systemctl", "--user", "kill", "-s", "HUP", unit }, out o);
            if (rc != 0) log_line ("[%s] reload failed: %s".printf (label, o));
            return rc == 0;
        }

        public async bool start (string core, string bin, string cfg_path, int port, int wait_sec = 5) {
            yield stop ();
            if (!(yield Tester.wait_port_free ((uint16) port))) {
                log_line ("[%s] not starting %s: %s".printf (label, core, Tester.port_taken_message ((uint16) port)));
                return false;
            }

            string mode = truncate_log ? "truncate:" : "append:";
            // use string[] for argv: GLib requires NULL terminator
            string[] argv = {
                "systemd-run", "--user", "--unit=" + unit, "--collect", "--quiet",
                "--description=Vector %s (%s)".printf (label, core),
                "-p", "Restart=on-failure", "-p", "RestartSec=1",
                "-p", "StandardOutput=" + mode + log_path, "-p", "StandardError=" + mode + log_path
            };
            if (core == Cores.XRAY) argv += "--setenv=XRAY_LOCATION_ASSET=" + Paths.data_dir ();
            argv += bin;
            argv += "run";
            argv += "-c";
            argv += cfg_path;

            string o;
            int rc = yield Util.run_command (argv, out o);
            if (rc != 0) {
                log_line ("[%s] systemd-run failed (%s); running %s as a child process".printf (label, o, core));
                try {
                    var launcher = new GLib.SubprocessLauncher (GLib.SubprocessFlags.NONE);
                    if (core == Cores.XRAY) launcher.setenv ("XRAY_LOCATION_ASSET", Paths.data_dir (), true);
                    launcher.set_stdout_file_path (log_path);
                    launcher.set_stderr_file_path (log_path);
                    launcher.set_child_setup (() => { Util.die_with_parent (); });
                    child = launcher.spawnv ({ bin, "run", "-c", cfg_path });
                    var p = child;
                    p.wait_async.begin (null, (obj, res) => {
                        try { p.wait_async.end (res); } catch (GLib.Error e) {}
                        if (child == p) child = null;
                    });
                } catch (GLib.Error e) {
                    log_line ("[%s] failed to start %s: %s".printf (label, core, e.message));
                    return false;
                }
            }

            bool up = false;
            var timer = new GLib.Timer ();
            while (!up && timer.elapsed () < wait_sec) {
                up = yield Tester.wait_for_port ((uint16) port, 10);
                if (!up && child == null && !(yield is_active ())) break; // exited / failed
            }
            if (!up) {
                log_line ("[%s] %s did not open port %d — see %s".printf (label, core, port, log_path));
                yield stop ();
                return false;
            }
            log_line ("[%s] %s is serving on 127.0.0.1:%d".printf (label, core, port));
            return true;
        }
    }
}
