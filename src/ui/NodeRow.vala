using Vector.Services;
namespace Vector.Ui {
    // shared layout flag: true in narrow windows to stack speed & ping vertically
    private class NodeRowLayout : GLib.Object {
        private static NodeRowLayout? instance = null;
        public bool compact { get; set; default = false; }
        public static NodeRowLayout get_default () {
            if (instance == null) instance = new NodeRowLayout ();
            return instance;
        }
    }

    // server row widget for GtkListView (recycled across items via bind/unbind)
    private class NodeRow : Gtk.Box {
        private Gtk.Label title;
        private Gtk.Label subtitle;
        private Gtk.Label latency_label;
        private Gtk.Label speed_label;
        private Gtk.Box metrics;
        private ulong layout_handler = 0;

        public bool show_group = false;

        private Models.Node? node = null;
        private ulong node_handler = 0;

        private const string[] LATENCY_CLASSES = { "latency-good", "latency-mid", "latency-bad" };
        private const string[] SPEED_CLASSES = { "speed-good", "speed-mid", "dim-label" };

        public signal void context_menu_requested (Models.Node n, double x, double y);

        public NodeRow () {
            Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 12);

            title = new Gtk.Label ("");
            title.xalign = 0.0f;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.add_css_class ("heading");

            subtitle = new Gtk.Label ("");
            subtitle.xalign = 0.0f;
            subtitle.ellipsize = Pango.EllipsizeMode.END;
            subtitle.add_css_class ("dim-label");
            subtitle.add_css_class ("caption");

            var text = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            text.hexpand = true;
            text.valign = Gtk.Align.CENTER;
            text.append (title);
            text.append (subtitle);

            latency_label = metric_label ();
            speed_label = metric_label ();
            metrics = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            metrics.valign = Gtk.Align.CENTER;
            metrics.append (latency_label);
            metrics.append (speed_label);

            append (text);
            append (metrics);

            var layout = NodeRowLayout.get_default ();
            apply_layout (layout.compact);
            layout_handler = layout.notify["compact"].connect (() => {
                apply_layout (NodeRowLayout.get_default ().compact);
            });

            // GtkListItem wrapper steals focus/styles, so poke "node-active" onto parent once mapped
            notify["parent"].connect (() => { refresh (); });
            map.connect (() => { refresh (); });

            var right_click = new Gtk.GestureClick ();
            right_click.button = 3;
            right_click.pressed.connect ((n_press, x, y) => {
                if (node != null) context_menu_requested (node, x, y);
            });
            add_controller (right_click);
        }

        private static Gtk.Label metric_label () {
            var label = new Gtk.Label ("");
            label.valign = Gtk.Align.CENTER;
            label.xalign = 1.0f;
            label.add_css_class ("numeric");
            return label;
        }

        public override void dispose () {
            if (layout_handler != 0) {
                NodeRowLayout.get_default ().disconnect (layout_handler);
                layout_handler = 0;
            }
            base.dispose ();
        }

        // compact: stack speed above ping in caption font; normal: side-by-side columns
        private void apply_layout (bool compact) {
            metrics.orientation = compact ? Gtk.Orientation.VERTICAL : Gtk.Orientation.HORIZONTAL;
            metrics.spacing = compact ? 0 : 12;
            metrics.reorder_child_after (compact ? speed_label : latency_label, null);
            foreach (var label in new Gtk.Label[] { latency_label, speed_label }) {
                set_class (label, "caption", compact);
                set_class (label, "numeric", !compact);
            }
            latency_label.width_request = compact ? 64 : 80;
            speed_label.width_request = compact ? 64 : 90;
            update_metric_visibility ();
        }

        // stacked layout quirk: hide empty metric labels so single values don't get shoved off-center
        private void update_metric_visibility () {
            bool compact = metrics.orientation == Gtk.Orientation.VERTICAL;
            latency_label.visible = !compact || latency_label.label != "";
            speed_label.visible = !compact || speed_label.label != "";
        }

        public void bind (Models.Node n) {
            unbind ();
            node = n;
            node_handler = n.notify.connect (() => { refresh (); });
            refresh ();
        }

        public void unbind () {
            if (node != null && node_handler != 0) node.disconnect (node_handler);
            node = null;
            node_handler = 0;
            show_active (false);
        }

        private void refresh () {
            if (node == null) return;
            title.label = node.name;
            string proto_label = node.is_auto () ? "%s auto×%d".printf (node.protocol, node.auto_count ())
                                                 : (node.protocol == "xray-json" ? "xray" : node.protocol);
            string sec_suffix = node.reality ? "/reality" : (node.tls ? "/tls" : "");
            string protocol = "%s • %s%s".printf (proto_label, node.network, sec_suffix);
            subtitle.label = show_group && node.group_name != "" ? "%s • %s".printf (node.group_name, protocol) : protocol;
            show_active (node.is_active);
            show_speed (node.speed_kbps);
            show_latency (node.latency);
            update_metric_visibility ();
        }

        private void show_active (bool active) {
            set_class (this, "node-active", active);
            var row = get_parent ();
            if (row != null) set_class (row, "node-active", active);
        }

        // -1 = untested, -2 = failed
        private void show_speed (int kbps) {
            switch (kbps) {
                case -1:
                    speed_label.label = "";
                    set_one_class (speed_label, SPEED_CLASSES, null);
                    break;
                case -2:
                    speed_label.label = "error";
                    set_one_class (speed_label, SPEED_CLASSES, "dim-label");
                    break;
                default:
                    speed_label.label = Util.format_speed (kbps);
                    // 1.25 MB/s = 10 Mbit/s
                    set_one_class (speed_label, SPEED_CLASSES, kbps >= 1280 ? "speed-good" : "speed-mid");
                    break;
            }
        }

        // -1 = untested, -2 = timeout
        private void show_latency (int ms) {
            switch (ms) {
                case -1:
                    latency_label.label = "";
                    set_one_class (latency_label, LATENCY_CLASSES, null);
                    break;
                case -2:
                    latency_label.label = "timeout";
                    set_one_class (latency_label, LATENCY_CLASSES, "latency-bad");
                    break;
                default:
                    latency_label.label = "%d ms".printf (ms);
                    string rating = ms < 300 ? "latency-good" : (ms < 800 ? "latency-mid" : "latency-bad");
                    set_one_class (latency_label, LATENCY_CLASSES, rating);
                    break;
            }
        }

        private static void set_class (Gtk.Widget widget, string css_class, bool on) {
            if (on) widget.add_css_class (css_class);
            else widget.remove_css_class (css_class);
        }

        private static void set_one_class (Gtk.Widget widget, string[] classes, string? chosen) {
            foreach (var c in classes) set_class (widget, c, c == chosen);
        }
    }
}
