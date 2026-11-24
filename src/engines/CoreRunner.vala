using Vector.Services;
using Vector.Testing;
namespace Vector.Engines {

    // router owns DNS and routing (and TUN), engine serves the proxy node
    public enum RouterKind {
        NONE,
        SERVICE,  // vector-tun.service
        SESSION,  // pkexec session router
        USER      // vector-proxy.service user unit
    }

    public class CoreRunner : GLib.Object {

        public signal void log_line (string line);
        public signal void state_changed (bool running);

        public bool running { get; private set; default = false; }
        public RouterKind router_kind { get; private set; default = RouterKind.NONE; }
        public bool tun_mode {
            get { return router_kind == RouterKind.SERVICE || router_kind == RouterKind.SESSION; }
        }

        public UserUnit engine;
        public UserUnit proxy_router;
        public SessionRouter session;

        private GLib.GenericArray<GLib.FileMonitor> tail_monitors = new GLib.GenericArray<GLib.FileMonitor> ();
        private GLib.HashTable<string, int64?> tail_offsets = new GLib.HashTable<string, int64?> (str_hash, str_equal);
        private LogFormatter log_fmt = new LogFormatter ();

        construct {
            engine = new UserUnit (Paths.engine_unit (), "engine", Paths.engine_log (), false);
            proxy_router = new UserUnit (Paths.proxy_router_unit (), "router", Paths.proxy_router_log (), true);
            session = new SessionRouter ();
            engine.log_line.connect ((l) => { log_line (l); });
            proxy_router.log_line.connect ((l) => { log_line (l); });
            session.log_line.connect ((l) => { log_line (l); });
            session.exited.connect (() => {
                if (router_kind != RouterKind.SESSION) return;
                log_line ("[app] the session TUN router exited — see %s.".printf (Paths.session_router_log ()));
                router_kind = RouterKind.NONE;
                stop ();
            });
        }

        private void emit_core_line (string raw, string source) {
            foreach (var l in log_fmt.process (raw, source)) log_line (l);
        }

        // validate config using the core binary before starting
        public async string? check_config (string core_name, string bin, string cfg_path, string? xray_assets) {
            string[] argv = Cores.uses_xray_config (core_name)
                ? new string[] { bin, "run", "-test", "-c", cfg_path }
                : new string[] { bin, "check", "-c", cfg_path };
            string output;
            try {
                var launcher = new GLib.SubprocessLauncher (
                    GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_PIPE);
                if (xray_assets != null) launcher.setenv ("XRAY_LOCATION_ASSET", xray_assets, true);
                var proc = launcher.spawnv (argv);
                string? out_str = null;
                string? err_str = null;
                yield proc.communicate_utf8_async (null, null, out out_str, out err_str);
                if (proc.get_if_exited () && proc.get_exit_status () == 0) return null;
                output = ((err_str ?? "") + "\n" + (out_str ?? "")).strip ();
            } catch (GLib.Error e) {
                // null here would mean "config is valid" — report the real
                // failure instead of silently passing a core that never ran.
                return "could not run the config check: " + e.message;
            }

            foreach (var line in output.split ("\n")) {
                string l = line.strip ();
                // Skip xray's version banner.
                if (l != "" && !l.has_prefix ("Xray ") && !l.has_prefix ("A unified ")) {
                    log_line ("[config-check] " + l);
                }
            }
            string[] lines = output.split ("\n");
            string last = lines.length > 0 ? lines[lines.length - 1].strip () : "Invalid configuration";
            last = strip_ansi (last);
            return last != "" ? last : "Configuration check failed";
        }

        // Cores colorize their log output (e.g. "\x1b[31mFATAL\x1b[0m"); the
        // last line goes into a toast, which must stay plain text.
        private static string strip_ansi (string s) {
            var sb = new GLib.StringBuilder ();
            bool esc = false;
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if (esc) {
                    // CSI: ESC '[' params letter — skip everything up to and
                    // including the final byte.
                    if (c.isalpha ()) esc = false;
                } else if (c == 0x1b) {
                    esc = true;
                } else {
                    sb.append_c (c);
                }
            }
            return sb.str;
        }

        // router may download missing rule-sets on start, allow up to timeout
        private static async bool wait_port (int port, int seconds) {
            var timer = new GLib.Timer ();
            while (timer.elapsed () < seconds) {
                if (yield Tester.wait_for_port ((uint16) port, 10)) return true;
            }
            return false;
        }

        private static string describe (RouterKind kind) {
            switch (kind) {
                case RouterKind.SERVICE: return "system service";
                case RouterKind.SESSION: return "session TUN";
                default:                 return "proxy";
            }
        }

        public static string router_log_for (RouterKind kind) {
            switch (kind) {
                case RouterKind.SESSION: return Paths.session_router_log ();
                case RouterKind.USER:    return Paths.proxy_router_log ();
                default:                 return Paths.router_log ();
            }
        }

        // Router lifecycle

        // Starts the router of `kind` with `cfg_path` (already validated) and
        // waits until it serves `port`. A session router that is alive but idle
        // is reloaded instead (no password). Returns an error, or null.
        public async string? start_router (RouterKind kind, string core, string bin, string cfg_path, int port) {
            string? err = null;
            switch (kind) {
                case RouterKind.SERVICE:
                    if (!(yield start_service ())) err = "the system service did not start — see %s".printf (Paths.router_log ());
                    break;
                case RouterKind.SESSION:
                    if (yield session.is_alive ()) {
                        if (!(yield session.reload ("tun")) || !(yield wait_port (port, 90))) {
                            err = "the session router did not take the new config — see %s".printf (Paths.session_router_log ());
                        }
                    } else {
                        err = yield session.start (bin, cfg_path, port);
                    }
                    break;
                case RouterKind.USER:
                    if (!(yield proxy_router.start (core, bin, cfg_path, port, 90))) {
                        err = "the router did not start — see %s".printf (Paths.proxy_router_log ());
                    }
                    break;
                default:
                    err = "no router";
                    break;
            }
            if (err != null) return err;
            router_kind = kind;
            start_tail (router_log_for (kind));
            if (!running) {
                running = true;
                state_changed (true);
            }
            return null;
        }

        // Re-reads the router config of the running router.
        public async bool reload_router () {
            switch (router_kind) {
                case RouterKind.SERVICE: return yield reload_service ();
                case RouterKind.SESSION: return yield session.reload ("tun");
                case RouterKind.USER:    return yield proxy_router.reload ();
                default:                 return false;
            }
        }

        // stop only router: keep engine running so switching TUN on/off is fast
        public async void stop_router () {
            var kind = router_kind;
            router_kind = RouterKind.NONE;
            stop_tail ();
            switch (kind) {
                case RouterKind.SERVICE:
                    yield stop_service ();
                    break;
                case RouterKind.SESSION:
                    yield idle_session_router ();
                    break;
                case RouterKind.USER:
                    yield proxy_router.stop ();
                    break;
                default:
                    break;
            }
        }

        private async void idle_session_router () {
            try {
                Util.write_private (Paths.router_json (), ConfigGenerator.gen_idle_router ());
            } catch (GLib.Error e) {
                log_line ("[app] could not write the idle router config (%s); stopping the session router.".printf (e.message));
                yield session.stop ();
                return;
            }
            if (!(yield session.reload ("idle"))) yield session.stop ();
            else log_line ("[app] session router idle (TUN off; no password needed to turn it back on).");
        }

        public void stop () {
            stop_async.begin ();
        }

        public async void stop_async () {
            yield stop_router ();
            yield engine.stop ();
            if (running) {
                running = false;
                log_line ("[app] stopped.");
                state_changed (false);
            }
        }

        // full exit also kills session router, so next run prompts password again
        public async void shutdown (bool full) {
            yield stop_async ();
            if (full) yield session.stop ();
        }

        // On app start: attach to whatever router is already up.
        public async void sync_state () {
            RouterKind kind = RouterKind.NONE;
            for (int attempt = 0; attempt < 3 && kind == RouterKind.NONE; attempt++) {
                string st = yield get_unit_state (Paths.tun_unit ());
                if (st == "active" || st == "activating") kind = RouterKind.SERVICE;
                else if (SessionRouter.mode () == "tun" && (yield session.is_alive ())) kind = RouterKind.SESSION;
                else if (yield proxy_router.is_active ()) kind = RouterKind.USER;
                else if (attempt < 2) yield Util.sleep_ms (300);
            }
            if (kind == RouterKind.NONE) {
                log_line ("[app] no router is running.");
                return;
            }
            router_kind = kind;
            running = true;
            start_tail (router_log_for (kind));
            log_line ("[app] attached to the running %s router.".printf (describe (kind)));
            GLib.Idle.add (() => {
                state_changed (true);
                return GLib.Source.REMOVE;
            });
        }

        // vector-tun.service (system bus)

        private const int POLL_MS = 200;

        private async bool start_service () {
            string unit = Paths.tun_unit ();
            try {
                string state = yield get_unit_state (unit);
                if (state == "failed") {
                    log_line ("[app] unit is in failed state — resetting before start.");
                    try {
                        yield systemd_manager ("ResetFailedUnit", new GLib.Variant ("(s)", unit), false);
                    } catch (GLib.Error e) {
                        log_line ("[app] ResetFailedUnit failed (non-fatal): " + e.message);
                    }
                    yield Util.sleep_ms (300);
                }
                if (state == "active") {
                    log_line ("[app] unit is already active — restarting it to apply the new config.");
                    yield systemd_manager ("RestartUnit", new GLib.Variant ("(ss)", unit, "replace"), true);
                } else {
                    yield systemd_manager ("StartUnit", new GLib.Variant ("(ss)", unit, "replace"), true);
                }
            } catch (GLib.Error e) {
                log_line ("[app] systemd start failed: " + e.message);
                return false;
            }

            switch (yield wait_unit_settled (unit)) {
                case "active":
                    log_line ("[app] %s is active.".printf (unit));
                    return true;
                case "failed":
                    log_line ("[app] %s entered failed state — check the router log.".printf (unit));
                    return false;
                default:
                    log_line ("[app] service did not become active — check the router log.");
                    return false;
            }
        }

        // Re-reads router.json (ExecReload = SIGHUP) without stopping the unit.
        private async bool reload_service () {
            string unit = Paths.tun_unit ();
            try {
                yield systemd_manager ("ReloadUnit", new GLib.Variant ("(ss)", unit, "replace"), true);
            } catch (GLib.Error e) {
                log_line ("[app] router reload failed: " + e.message);
                return false;
            }
            if ((yield wait_unit_settled (unit)) == "active") return true;
            log_line ("[app] router did not come back after reload — check router.log.");
            return false;
        }

        private async void stop_service () {
            string unit = Paths.tun_unit ();
            try {
                yield systemd_manager ("StopUnit", new GLib.Variant ("(ss)", unit, "replace"), true);
            } catch (GLib.Error e) {
                // Not running or not loaded.
            }
            for (int i = 0; i < 15; i++) {
                string state = yield get_unit_state (unit);
                if (state != "active" && state != "deactivating") break;
                yield Util.sleep_ms (POLL_MS);
            }
        }

        // Polls for up to 6 s until the unit is "active" or "failed"; returns
        // the last state seen.
        private async string wait_unit_settled (string unit) {
            string state = "unknown";
            for (int i = 0; i < 30; i++) {
                state = yield get_unit_state (unit);
                if (state == "active" || state == "failed") break;
                yield Util.sleep_ms (POLL_MS);
            }
            return state;
        }

        // "unknown" when the unit was never loaded (NoSuchUnit).
        private async string get_unit_state (string unit) {
            try {
                var reply = yield systemd_manager ("GetUnit", new GLib.Variant ("(s)", unit), false,
                                                   new GLib.VariantType ("(o)"));
                string obj_path;
                reply.get ("(o)", out obj_path);
                var bus = yield GLib.Bus.get (GLib.BusType.SYSTEM, null);
                var prop = yield bus.call (
                    "org.freedesktop.systemd1", obj_path,
                    "org.freedesktop.DBus.Properties", "Get",
                    new GLib.Variant ("(ss)", "org.freedesktop.systemd1.Unit", "ActiveState"),
                    new GLib.VariantType ("(v)"),
                    GLib.DBusCallFlags.NONE, -1, null);
                GLib.Variant inner;
                prop.get ("(v)", out inner);
                return inner.get_string ();
            } catch (GLib.Error e) {
                return "unknown";
            }
        }

        // Calls a method of the system systemd manager. `interactive` lets
        // polkit ask for a password (the installed rule makes it password-less).
        private static async GLib.Variant systemd_manager (string method, GLib.Variant parameters, bool interactive,
                                                           GLib.VariantType? reply_type = null) throws GLib.Error {
            var bus = yield GLib.Bus.get (GLib.BusType.SYSTEM, null);
            return yield bus.call (
                "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
                "org.freedesktop.systemd1.Manager", method, parameters, reply_type,
                interactive ? GLib.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION : GLib.DBusCallFlags.NONE,
                -1, null);
        }

        // Log tail

        // Tails the router log plus the engine log into log_line.
        internal void start_tail (string path) {
            stop_tail ();
            foreach (var p in new string[] { path, Paths.engine_log () }) {
                tail_one (p);
            }
        }

        private void tail_one (string path) {
            var f = GLib.File.new_for_path (path);
            int64 offset = 0;
            try {
                offset = f.query_info (GLib.FileAttribute.STANDARD_SIZE, GLib.FileQueryInfoFlags.NONE).get_size ();
            } catch (GLib.Error e) {}
            tail_offsets.insert (path, offset);
            try {
                var mon = f.monitor_file (GLib.FileMonitorFlags.NONE);
                mon.changed.connect ((src, other, event) => {
                    if (event == GLib.FileMonitorEvent.CHANGES_DONE_HINT ||
                        event == GLib.FileMonitorEvent.CHANGED ||
                        event == GLib.FileMonitorEvent.CREATED) {
                        read_new_log_bytes (path);
                    }
                });
                tail_monitors.add (mon);
            } catch (GLib.Error e) {
                log_line ("[app] failed to monitor log file: " + e.message);
            }
        }

        // Emits only complete lines and advances the offset by exactly the bytes
        // consumed, so a line the core is still writing is neither lost nor
        // shown twice.
        private void read_new_log_bytes (string path) {
            string source = path == Paths.engine_log () ? "engine" : "router";
            try {
                var f = GLib.File.new_for_path (path);
                int64? off = tail_offsets.lookup (path);
                int64 offset = off ?? 0;
                int64 size = f.query_info (GLib.FileAttribute.STANDARD_SIZE, GLib.FileQueryInfoFlags.NONE).get_size ();
                if (size < offset) offset = 0; // truncated (unit restarted)
                if (size == offset) return;
                var stream = f.read ();
                stream.seek (offset, GLib.SeekType.SET);
                var bytes = stream.read_bytes ((size_t) (size - offset));
                stream.close ();
                unowned uint8[] data = bytes.get_data ();
                int start = 0;
                for (int i = 0; i < data.length; i++) {
                    if (data[i] != '\n') continue;
                    // Copy exactly i - start bytes: the slice is not NUL-terminated.
                    var sb = new GLib.StringBuilder.sized (i - start + 1);
                    sb.append_len ((string) data[start:i], i - start);
                    string line = sb.str.make_valid ();
                    emit_core_line (line, source);
                    start = i + 1;
                }
                tail_offsets.insert (path, offset + start);
            } catch (GLib.Error e) {}
        }

        private void stop_tail () {
            foreach (var m in tail_monitors) m.cancel ();
            tail_monitors = new GLib.GenericArray<GLib.FileMonitor> ();
            tail_offsets.remove_all ();
        }
    }
}
