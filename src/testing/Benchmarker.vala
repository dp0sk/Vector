using Vector.Models;
using Vector.Services;
namespace Vector.Testing {

    public class BenchResult : GLib.Object {
        public Models.Node node;
        public int  latency_ms; // -1 = unbenchmarked, -2 = dead/timed out
        public int  speed_kbps; // -1 = skipped, -2 = error

        public BenchResult (Models.Node n, int lat, int spd) {
            node       = n;
            latency_ms = lat;
            speed_kbps = spd;
        }
    }

    // parallel batch tester for nodes.
    // keep running flag active until every single worker has actually returned,
    // otherwise starting a new benchmark immediately collides with lingering worker processes
    public class Benchmarker : GLib.Object {

        public signal void node_done (BenchResult result);
        public signal void all_done  (uint tested, uint skipped, uint errors);

        public bool running   { get; private set; default = false; }
        public bool cancelled { get; private set; default = false; }
        public bool run_speed { get; private set; default = false; }

        private GLib.Cancellable cancellable = new GLib.Cancellable ();

        private GLib.GenericArray<Models.Node> queue = new GLib.GenericArray<Models.Node> ();
        private GLib.GenericArray<string> cores = new GLib.GenericArray<string> ();
        private GLib.HashTable<string, string> binaries = new GLib.HashTable<string, string> (str_hash, str_equal);
        private string ping_url = "";
        private string speed_url = "";
        private int timeout_sec = 10;

        private int next = 0;
        private int workers_left = 0;
        private uint tested = 0;
        private uint skipped = 0;
        private uint errors = 0;

        public void start (GLib.GenericArray<Models.Node> nodes, GLib.GenericArray<string> cores,
                           GLib.HashTable<string, string> bins, string ping_url, string speed_url,
                           int parallelism = 8, bool run_speed = false, int timeout_sec = 10) {
            if (running) return;
            running = true;
            cancelled = false;
            cancellable = new GLib.Cancellable ();
            this.run_speed = run_speed;
            this.queue = nodes;
            this.cores = cores;
            this.binaries = bins;
            this.ping_url = url_or_random (ping_url, AppSettings.PING_TEST_URLS);
            this.speed_url = url_or_random (speed_url, AppSettings.SPEED_TEST_URLS);
            this.timeout_sec = timeout_sec;
            next = 0;
            tested = skipped = errors = 0;

            // nuke stale latencies upfront so the UI rows immediately flip to "testing..."
            foreach (var n in nodes) {
                n.latency = -1;
                if (run_speed) n.speed_kbps = -1;
            }

            workers_left = int.min (int.max (1, parallelism), (int) nodes.length);
            if (workers_left == 0) {
                finish ();
                return;
            }
            for (int w = 0, count = workers_left; w < count; w++) worker.begin ();
        }

        // cancel in-flight test: abort worker loops and tear down pending probes
        public void cancel () {
            if (!running) return;
            cancelled = true;
            cancellable.cancel ();
        }

        private static string url_or_random (string url, string[] builtin) {
            string u = url.strip ();
            if (u != "" && u != "auto") return u;
            return builtin[GLib.Random.int_range (0, builtin.length)];
        }

        private async void worker () {
            while (!cancelled && next < queue.length) {
                int i = next++;
                var node = queue[i];
                int latency, speed;
                yield Tester.probe_node (node, cores[i], binaries.lookup (cores[i]), ping_url, speed_url,
                                         run_speed, timeout_sec, cancellable, out latency, out speed);
                if (cancelled) break; // cancelled mid-probe: discard and don't count as failure
                if (!run_speed) speed = node.speed_kbps; // ping-only test preserves existing speed test score
                count_result (latency, speed);

                node.latency = latency;
                node.speed_kbps = speed;
                var result = new BenchResult (node, latency, speed);
                GLib.Idle.add (() => {
                    node_done (result);
                    return GLib.Source.REMOVE;
                });
            }
            if (--workers_left == 0) finish ();
        }

        // skip speed test if ping failed or timed out
        private void count_result (int latency, int speed) {
            tested++;
            if (latency <= 0) {
                errors++;
                if (run_speed) skipped++;
            } else if (run_speed && speed < 0) {
                errors++;
            }
        }

        private void finish () {
            running = false;
            uint t = tested, s = skipped, e = errors;
            GLib.Idle.add (() => {
                all_done (t, s, e);
                return GLib.Source.REMOVE;
            });
        }
    }
}
