using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private void on_row_activated (Models.Node node) {
            if (node == active_node && runner.running) {
                return;
            }
            start_flow_for.begin (node);
        }

        // router + backend engine split:
        // Everything proxies through a frontend router (DNS, rules, TUN interface) in front of an
        // unprivileged engine serving the node on settings.engine_port.
        // - TUN: systemd service if installed, otherwise session router (pkexec once per login, see SessionRouter)
        // - proxy: vector-proxy user service (no TUN)
        // Both bind current_mixed_port for desktop proxy. Changing node/core only touches the engine;
        // toggling TUN only restarts the router.

        // which core compiles routing rules (.srs files)
        private string routing_core () {
            if (SystemdInstaller.router_installed ()) return SystemdInstaller.installed_router_core ();
            return settings.tun_router_core;
        }

        // pinned router binary handles service & proxy mode so routing rules behave consistently.
        // session router falls back to app copy if service isn't installed.
        private bool uses_pinned_router (RouterKind kind) {
            return kind == RouterKind.SERVICE || (kind == RouterKind.USER && SystemdInstaller.router_installed ());
        }

        private string engine_core_for (Models.Node n) {
            return Cores.engine_core_for (n, settings);
        }

        private int ensure_engine_port () {
            if (settings.engine_port <= 0) {
                uint16 p = Tester.ephemeral_port ();
                settings.engine_port = p > 0 ? (int) p : 20808;
                settings.save ();
            }
            return settings.engine_port;
        }

        private bool write_private (string path, string content) {
            try {
                Util.write_private (path, content);
                return true;
            } catch (GLib.Error e) {
                show_toast ("Failed to write %s: %s".printf (GLib.Path.get_basename (path), e.message));
                return false;
            }
        }

        // cache core + cfg sig so toggling TUN/proxy doesn't needlessly bounce the engine
        private string engine_signature = "";

        private async bool start_engine_for (Models.Node node, bool reuse = false) {
            string core = engine_core_for (node);
            string? bin = runner.engine.stable_binary (core);
            if (bin == null) {
                show_toast ("Core '%s' not found — see Logs.".printf (core));
                append_log ("[app] core lookup failed; searched: " + Paths.search_description ());
                return false;
            }
            int port = ensure_engine_port ();
            string cfg = ConfigGenerator.gen_engine_for (core, node, port, settings);
            if (cfg == "") {
                // xray config parser choked hard - bail now before throwing cryptic error from core test
                show_toast ("Stored Xray config for '%s' is corrupt — re-import the node.".printf (node.name));
                append_log ("[app] engine config generation returned nothing for '%s'".printf (node.name));
                return false;
            }
            string sig = core + "\n" + cfg;
            if (reuse && sig == engine_signature && (yield runner.engine.is_active ())) return true;
            if (!write_private (Paths.engine_json (), cfg)) return false;
            string? assets = Cores.uses_xray_config (core) ? Paths.data_dir () : null;
            string? err = yield runner.check_config (core, bin, Paths.engine_json (), assets);
            if (err != null) {
                show_toast ("Config error: %s".printf (err));
                return false;
            }
            append_log ("[app] engine %s for '%s' on 127.0.0.1:%d".printf (core, node.name, port));
            if (!(yield runner.engine.start (core, bin, Paths.engine_json (), port))) {
                engine_signature = "";
                show_toast ("Engine %s failed to start — see Logs.".printf (core));
                return false;
            }
            engine_signature = sig;
            return true;
        }

        // hot-swap engine if user switched core in settings while connected
        public void apply_engine_change () {
            if (!runner.running) return;
            var n = active_node != null ? active_node : current_selected_node ();
            if (n == null) return;
            start_engine_for.begin (n, true, (obj, res) => {
                if (start_engine_for.end (res)) check_connection_status.begin (false);
            });
        }

        private RouterKind router_kind_for (bool tun) {
            if (!tun) return RouterKind.USER;
            return SystemdInstaller.router_installed () ? RouterKind.SERVICE : RouterKind.SESSION;
        }

        // validate config first, then reload or boot router
        private async bool apply_router (RouterKind kind) {
            bool tun = kind != RouterKind.USER;
            bool pinned = uses_pinned_router (kind);
            string core = pinned ? SystemdInstaller.installed_router_core () : settings.tun_router_core;
            string? cfg = ConfigGenerator.gen_router_for (
                core, settings, store.get_active_routing_preset (), ensure_engine_port (), tun);
            if (cfg == null) {
                show_toast ("Router core '%s' is not supported by this version.".printf (core));
                return false;
            }
            string? bin = pinned ? Paths.ROUTER_BIN : runner.engine.stable_binary (core);
            if (bin == null) {
                show_toast ("Core '%s' not found — see Logs.".printf (core));
                append_log ("[app] core lookup failed; searched: " + Paths.search_description ());
                return false;
            }
            string path = tun ? Paths.router_json () : Paths.proxy_router_json ();
            bool same_running = runner.running && runner.router_kind == kind;
            string old = "";
            try { GLib.FileUtils.get_contents (path, out old); } catch (GLib.Error e) {}
            if (same_running && old == cfg) return true;

            string staged = path + ".new";
            if (!write_private (staged, cfg)) return false;
            string? err = yield runner.check_config (core, bin, staged, null);
            if (err != null) {
                GLib.FileUtils.unlink (staged);
                show_toast ("Router config error: %s".printf (err));
                return false;
            }
            if (GLib.FileUtils.rename (staged, path) != 0) {
                show_toast ("Failed to write %s".printf (GLib.Path.get_basename (path)));
                return false;
            }
            if (same_running) {
                append_log ("[app] routing changed — reloading router.");
                return yield runner.reload_router ();
            }
            err = yield runner.start_router (kind, core, bin, path, settings.current_mixed_port);
            if (err != null) {
                show_toast ("Router: %s".printf (err));
                append_log ("[app] router start failed: " + err);
                return false;
            }
            return true;
        }

        // router is alive but engine died or session restarted, bring it back
        private async void ensure_engine_alive () {
            if (!runner.running) return;
            if (yield runner.engine.is_active ()) return;
            var n = active_node;
            if (n == null) return;
            append_log ("[app] router is up but no engine is running — starting engine for '%s'.".printf (n.name));
            yield start_engine_for (n);
        }

        private const string ROUTER_REINSTALL_MSG =
            "TUN needs the updated system service: Service → System Service → Install (one password prompt).";

        // session TUN fallback: warn user before triggering pkexec prompt
        private async RouterKind confirm_session_tun () {
            if (yield runner.session.is_alive ()) return RouterKind.SESSION; // already authorized this session
            string missing = SessionRouter.missing_tool ();
            var dialog = new Adw.AlertDialog ("Turn On TUN?", null);
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("install", "Install as System Service");
            if (missing == "") {
                dialog.body = "TUN needs administrator rights. Vector will ask for your password once, " +
                    "and TUN then works until you log out.\n\n" +
                    "To never be asked again, install the system service (also one password prompt).";
                dialog.add_response ("session", "Start for This Session");
                dialog.set_response_appearance ("session", Adw.ResponseAppearance.SUGGESTED);
                dialog.default_response = "session";
            } else {
                dialog.body = "TUN without the system service needs '%s', which is not installed. ".printf (missing) +
                    "Install the system service instead (one password prompt).";
                dialog.set_response_appearance ("install", Adw.ResponseAppearance.SUGGESTED);
                dialog.default_response = "install";
            }
            dialog.close_response = "cancel";
            string resp = yield dialog.choose (this, null);
            if (resp == "session") return RouterKind.SESSION;
            if (resp == "install" && (yield install_tun_service ())) return RouterKind.SERVICE;
            return RouterKind.NONE;
        }

        // user cancelled auth: rollback UI switch
        private void cancel_tun_start () {
            if (runner.running) {
                updating_ui = true;
                tun_switch.active = false;
                start_button.active = true;
                updating_ui = false;
                settings.tun_enabled = false;
                settings.save ();
            } else {
                revert_toggle ();
            }
        }

        private bool flow_running = false;
        private Models.Node? flow_pending = null;

        // serialize connect flow so spamming toggles doesn't race.
        // rapid clicks used to kill session router mid-flight and re-trigger polkit prompts, which sucked balls.
        private async void start_flow_for (Models.Node node) {
            if (flow_running) {
                flow_pending = node;
                return;
            }
            flow_running = true;
            Models.Node? next = node;
            while (next != null) {
                flow_pending = null;
                yield run_flow (next);
                next = flow_pending;
            }
            flow_running = false;
        }

        private async void run_flow (Models.Node node) {
            if (config_changed_toast != null) config_changed_toast.dismiss ();
            bool tun = tun_switch.active;

            // don't touch old installed service with busted API, tell user to reinstall
            if (tun && SystemdInstaller.service_present ()
                && (!SystemdInstaller.router_installed () || !SystemdInstaller.router_version_current ())) {
                show_toast (ROUTER_REINSTALL_MSG);
                append_log ("[app] TUN router not installed (installed API %d, need %d).".printf (
                    SystemdInstaller.installed_api (), SystemdInstaller.ROUTER_API));
                if (SystemdInstaller.router_installed ()) {
                    append_log ("[app] installed router core is older than the bundled one — reinstall the service.");
                }
                cancel_tun_start ();
                return;
            }

            RouterKind kind = router_kind_for (tun);
            if (kind == RouterKind.SESSION && !(runner.running && runner.router_kind == RouterKind.SESSION)) {
                kind = yield confirm_session_tun ();
                if (kind == RouterKind.NONE) {
                    cancel_tun_start ();
                    return;
                }
            }

            bool was_running = runner.running;
            RouterKind prev_kind = runner.router_kind;
            bool hot = was_running && runner.router_kind == kind;
            if (was_running && !hot) {
                append_log ("[app] switching router (%s).".printf (tun ? "TUN on" : "TUN off"));
                yield runner.stop_router ();
            }
            // keep mixed port stable while connected so desktop proxy doesn't choke
            if (!was_running) {
                if (settings.random_mixed_port) {
                    uint16 ep = Tester.ephemeral_port ();
                    settings.current_mixed_port = ep > 0 ? (int) ep : settings.mixed_port;
                } else {
                    settings.current_mixed_port = settings.mixed_port;
                }
            }

            bool ok = (yield start_engine_for (node, true)) && (yield apply_router (kind));
            if (!ok && was_running && !hot && runner.router_kind == RouterKind.NONE) {
                // router failed to boot (auth cancelled?), rollback to previous one
                append_log ("[app] restoring the previous router.");
                if (yield apply_router (prev_kind)) {
                    updating_ui = true;
                    tun_switch.active = runner.tun_mode;
                    start_button.active = true;
                    updating_ui = false;
                    settings.tun_enabled = runner.tun_mode;
                    settings.save ();
                    check_connection_status.begin (false);
                    return;
                }
            }
            if (!ok) {
                if (runner.router_kind == RouterKind.NONE) {
                    // dead in the water, kill engine and reset button
                    if (runner.running) yield runner.stop_async ();
                    else yield runner.engine.stop ();
                    revert_toggle ();
                }
                return;
            }
            set_active (node);
            sync_system_proxy ();
            if (was_running) check_connection_status.begin (false);

            updating_ui = true;
            start_button.active = true;
            tun_switch.active = runner.tun_mode;
            updating_ui = false;
        }

        private async void start_flow () {
            var node = current_selected_node ();
            if (node == null) {
                if (active_node != null) {
                    node = active_node;
                } else {
                    show_toast ("Select a server first.");
                    revert_toggle ();
                    return;
                }
            }
            yield start_flow_for (node);
        }

        // if protocol is pinned to a specific core (e.g. xray for xhttp), ignore default core switch
        public async void switch_core (string new_core) {
            if (settings.core == new_core) return;

            append_log ("[app] default core: %s -> %s".printf (settings.core, new_core));
            settings.core = new_core;
            settings.save ();

            updating_ui = true;
            if (core_row != null) core_row.selected = (new_core == "xray" ? 1 : 0);
            updating_ui = false;
            refresh_protocol_rows ();

            var node = active_node != null ? active_node : current_selected_node ();
            if (!runner.running || node == null) {
                show_toast ("Default core: %s".printf (new_core));
                return;
            }
            string used = engine_core_for (node);
            if (used != new_core) {
                show_toast ("'%s' keeps the %s engine (Core per protocol).".printf (node.name, used));
                return;
            }
            if (yield start_engine_for (node, true)) {
                show_toast ("Switched to %s".printf (new_core));
                check_connection_status.begin (false);
            }
        }

        // random mixed port might change on reconnect, gotta update desktop proxy settings
        private void sync_system_proxy () {
            if (settings.sysproxy_mode == 1) {
                SystemProxy.apply (settings);
            }
        }

        private uint config_changed_timeout = 0;
        private Adw.Toast? config_changed_toast = null;

        // debounce config changes so typing into entry rows doesn't spam toasts
        private void notify_config_changed () {
            if (!runner.running) return;
            if (config_changed_timeout != 0) GLib.Source.remove (config_changed_timeout);
            config_changed_timeout = GLib.Timeout.add (800, () => {
                config_changed_timeout = 0;
                if (!runner.running || config_changed_toast != null) return GLib.Source.REMOVE;
                var toast = new Adw.Toast ("Settings changed. Reconnect to apply.");
                toast.button_label = "Reconnect";
                toast.timeout = 0;
                toast.button_clicked.connect (() => {
                    var n = active_node != null ? active_node : current_selected_node ();
                    if (n != null && runner.running) start_flow_for.begin (n);
                });
                toast.dismissed.connect (() => { config_changed_toast = null; });
                config_changed_toast = toast;
                toast_overlay.add_toast (toast);
                return GLib.Source.REMOVE;
            });
        }
    }
}
