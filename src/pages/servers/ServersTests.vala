using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private Gtk.Button bench_ping_btn;
        private Gtk.Button bench_speed_btn;

        // queued test: -1 none, 0 delay, 1 delay + speed
        private int pending_bench = -1;

        private async void test_single_node (Models.Node n, bool with_speed) {
            string core = engine_core_for (n);
            string? bin = Paths.find_core (core);
            if (bin == null) {
                show_toast ("Core '%s' not found.".printf (core));
                return;
            }

            show_toast ("Testing '%s'\u2026".printf (n.name));

            int lat, spd;
            yield Tester.probe_node (n, core, bin, settings.ping_url, settings.speed_url,
                                     with_speed, settings.test_timeout, null, out lat, out spd);
            if (!with_speed) spd = n.speed_kbps;

            n.latency = lat;
            n.speed_kbps = spd;

            if (current_sort_col == "ping" || current_sort_col == "speed") {
                schedule_dynamic_sort ();
            }

            if (lat <= 0) {
                show_toast ("'%s': timeout".printf (n.name));
            } else if (!with_speed) {
                show_toast ("'%s': %d ms".printf (n.name, lat));
            } else if (spd > 0) {
                show_toast ("'%s': %d ms, %s".printf (n.name, lat, Util.format_speed (spd)));
            } else {
                show_toast ("'%s': %d ms, speed test failed".printf (n.name, lat));
            }
        }

        private void connect_benchmark_signals () {
            benchmarker.node_done.connect ((result) => {
                if (current_sort_col == "ping" || current_sort_col == "speed") {
                    schedule_dynamic_sort ();
                }
            });

            benchmarker.all_done.connect ((tested, skipped, errors) => {
                if (sort_throttle_id != 0) {
                    GLib.Source.remove (sort_throttle_id);
                    sort_throttle_id = 0;
                }
                if (pending_bench >= 0) {
                    // switched to the other test: no "stopped" toast, just start it
                    append_log ("[app] Test stopped: %u tested.".printf (tested));
                    start_pending_benchmark ();
                    return;
                }
                update_bench_buttons ();
                string summary = skipped > 0
                    ? "Test %s: %u tested, %u skipped, %u errors.".printf (benchmarker.cancelled ? "stopped" : "complete", tested, skipped, errors)
                    : "Test %s: %u tested, %u timeout/error.".printf (benchmarker.cancelled ? "stopped" : "complete", tested, errors);
                append_log ("[app] " + summary);
                show_toast (summary);
                if (current_sort_col == "ping" || current_sort_col == "speed") {
                    if (current_sorter != null) {
                        current_sorter.changed (Gtk.SorterChange.DIFFERENT);
                    } else {
                        refresh_sorting ();
                    }
                    restore_active_selection ();
                }
            });
        }

        // running test button turns into "Stop"; clicking the other one schedules a hot-switch
        public void update_bench_buttons () {
            bool busy = benchmarker.running && !benchmarker.cancelled;
            int shown = busy ? (benchmarker.run_speed ? 1 : 0) : pending_bench;
            bool ping_stop = shown == 0;
            bool speed_stop = shown == 1;
            bench_ping_btn.icon_name = ping_stop ? "media-playback-stop-symbolic" : "vertical-arrows-symbolic";
            bench_ping_btn.tooltip_text = ping_stop ? "Stop test" : "Real delay test";
            bench_speed_btn.icon_name = speed_stop ? "media-playback-stop-symbolic" : "speedometer-symbolic";
            bench_speed_btn.tooltip_text = speed_stop ? "Stop test" : "Real delay & speed test";
        }

        public void start_pending_benchmark () {
            if (pending_bench < 0) return;
            bool speed = pending_bench == 1;
            pending_bench = -1;
            run_benchmark (speed);
        }

        // same button cancels test; opposite button cancels current run and queues itself
        private void run_benchmark (bool run_speed) {
            if (benchmarker.running) {
                int want = run_speed ? 1 : 0;
                bool same = benchmarker.cancelled ? pending_bench == want
                                                  : benchmarker.run_speed == run_speed;
                if (same) {
                    pending_bench = -1;
                    if (!benchmarker.cancelled) {
                        benchmarker.cancel ();
                        append_log ("[app] test stop requested.");
                    }
                } else {
                    pending_bench = want;
                    if (!benchmarker.cancelled) {
                        benchmarker.cancel ();
                        append_log ("[app] switching test: %s.".printf (run_speed ? "delay + speed" : "delay"));
                    }
                }
                update_bench_buttons ();
                return;
            }
            // test only servers shown in current tab ("All" covers everything)
            Gtk.SortListModel? tab_model = null;
            string scope = "All";
            var sel_page = server_tabs.selected_page;
            if (sel_page != null && sel_page.child != null) {
                tab_model = sel_page.child.get_data<Gtk.SortListModel> ("sort_model");
                scope = sel_page.title;
            }
            GLib.ListModel source = tab_model != null ? (GLib.ListModel) tab_model : (GLib.ListModel) store.nodes;
            uint count = source.get_n_items ();
            if (count == 0) {
                show_toast ("No nodes to test in '%s'.".printf (scope));
                return;
            }
            // test each node using its target engine core
            var arr = new GLib.GenericArray<Models.Node> ();
            var cores = new GLib.GenericArray<string> ();
            var bins = new GLib.HashTable<string, string> (str_hash, str_equal);
            for (uint i = 0; i < count; i++) {
                var n = (Models.Node) source.get_item (i);
                string core = engine_core_for (n);
                if (!bins.contains (core)) {
                    string? b = Paths.find_core (core);
                    if (b == null) {
                        show_toast ("Core '%s' not found — see Logs.".printf (core));
                        append_log ("[app] core lookup failed; searched: " + Paths.search_description ());
                        return;
                    }
                    bins.insert (core, b);
                }
                arr.add (n);
                cores.add (core);
            }
            string bin = string.joinv (", ", bins.get_keys_as_array ());

            int workers = settings.concurrent_tests > 0 ? settings.concurrent_tests : 16;
            benchmarker.start (arr, cores, bins, settings.ping_url, settings.speed_url, workers, run_speed, settings.test_timeout);
            update_bench_buttons ();

            if (current_sort_col == "ping" || current_sort_col == "speed") {
                schedule_dynamic_sort ();
            }

            string msg = run_speed ? "Real delay + speed test started" : "Real delay test started";
            append_log ("[app] %s in '%s': %u nodes, %d workers, via %s.".printf (msg, scope, count, workers, bin));
            show_toast (msg);
        }
    }
}
