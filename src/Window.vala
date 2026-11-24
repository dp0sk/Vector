using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow : Adw.ApplicationWindow {

        private AppSettings settings;
        private Store store;
        private CoreRunner runner;
        private SubscriptionManager sub_mgr;
        private GeoManager geo_mgr;
        private SystemdInstaller installer;
        private Benchmarker benchmarker;
        private TrayIcon tray_icon;

        private Adw.OverlaySplitView split_view;
        private Adw.WindowTitle content_title;
        private Adw.ToastOverlay toast_overlay;
        private Gtk.Stack content_stack;
        private Gtk.ListBox nav_list;
        private Gtk.ToggleButton sidebar_toggle_btn;

        private Gtk.ToggleButton start_button;
        private Adw.ButtonContent start_button_content;
        private Gtk.Label active_label;
        private Gtk.Label ip_label;
        private Gtk.Label country_label;
        private Gtk.DropDown sysproxy_dropdown;
        private Gtk.Switch tun_switch;
        private Gtk.Button info_btn;
        private Gtk.Button locate_btn;
        private Gtk.Box bottom_panel;
        private Gtk.Box bottom_left_box;
        private Gtk.Box bottom_right_box;
        private Gtk.Box bottom_controls_box;
        private MatchWidthBin start_bin;

        private Models.Node? active_node = null;
        private bool updating_ui = false;
        private uint net_change_timer_id = 0;
        private bool app_held = false;

        public MainWindow (Adw.Application app) {
            int init_w = 1080, init_h = 740;
            string? sw = GLib.Environment.get_variable ("VECTOR_WINDOW_WIDTH");
            string? sh = GLib.Environment.get_variable ("VECTOR_WINDOW_HEIGHT");
            if (sw != null && int.parse (sw) > 0) init_w = int.parse (sw);
            if (sh != null && int.parse (sh) > 0) init_h = int.parse (sh);
            Object (application: app, title: "Vector", default_width: init_w, default_height: init_h);

            set_size_request (360, 360);

            Paths.ensure ();
            settings = new AppSettings ();
            ConfigGenerator.bind_xray_to_default_interface = true;
            settings.load ();
            store = new Store ();
            store.load ();
            runner = new CoreRunner ();
            sub_mgr = new SubscriptionManager ();
            geo_mgr = new GeoManager ();
            installer = new SystemdInstaller ();
            benchmarker = new Benchmarker ();
            tray_icon = new TrayIcon (this, runner);

            build_ui ();

            runner.log_line.connect (append_log);
            runner.state_changed.connect (on_state_changed);
            runner.sync_state.begin ();

            connect_benchmark_signals ();

            close_request.connect (() => {
                if (settings.run_app_in_background) {
                    visible = false;
                    return true;
                }
                if (!settings.run_tunnel_in_background) {
                    release_system_proxy ();
                    // keep app alive until background services stop
                    application.hold ();
                    runner.shutdown.begin (false, (obj, res) => {
                        runner.shutdown.end (res);
                        application.release ();
                    });
                }
                if (app_held) {
                    application.release ();
                    app_held = false;
                }
                return false;
            });

            setup_auto_update_timer ();
            setup_network_monitor ();
        }

        private void setup_network_monitor () {
            var net_mon = GLib.NetworkMonitor.get_default ();
            net_mon.network_changed.connect ((available) => {
                if (!available || !runner.running || active_node == null) return;
                if (net_change_timer_id != 0) {
                    GLib.Source.remove (net_change_timer_id);
                }
                net_change_timer_id = GLib.Timeout.add (1500, () => {
                    net_change_timer_id = 0;
                    // xray stays bound to old interface, restart engine on network change
                    if (runner.running && active_node != null) apply_engine_change ();
                    return GLib.Source.REMOVE;
                });
            });
        }

        public void full_exit () {
            release_system_proxy ();
            runner.shutdown.begin (true, (obj, res) => {
                runner.shutdown.end (res);
                application.quit ();
            });
        }

        // don't touch proxy settings if user selected "Off proxy"
        private void release_system_proxy () {
            if (settings.sysproxy_mode == 1) SystemProxy.clear ();
        }

        private void on_node_edited (Models.Node n) {
            if (n != active_node || !runner.running) return;
            show_toast ("Applying changes to '%s'…".printf (n.name));
            apply_engine_change (); // only restart engine, router stays running
        }

        // UI Construction

        private class PageDef {
            public string icon;
            public string title;
            public string name;
            public PageDef (string icon, string title, string name) {
                this.icon = icon;
                this.title = title;
                this.name = name;
            }
        }
        private PageDef[] PAGES = {
            new PageDef ("proxy-server-symbolic",            "Servers", "servers"),
            new PageDef ("rss-symbolic",                     "Groups",  "subs"),
            new PageDef ("condition-symbolic",              "Route",   "route"),
            new PageDef ("application-x-sharedlib-symbolic", "Core",    "core"),
            new PageDef ("3d-box-symbolic",                 "Service", "service"),
            new PageDef ("terminal-symbolic",                "Logs",    "logs")
        };

        private void build_ui () {
            updating_ui = true;
            restore_active_node_state ();

            build_bottom_bar ();

            content_stack = new Gtk.Stack ();
            content_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            content_stack.add_named (build_servers_page (), "servers");
            content_stack.add_named (build_subs_page (), "subs");
            content_stack.add_named (build_route_page (), "route");
            content_stack.add_named (build_core_page (), "core");
            content_stack.add_named (build_service_page (), "service");
            content_stack.add_named (build_log_page (), "logs");

            split_view = new Adw.OverlaySplitView ();
            split_view.sidebar = build_sidebar ();
            split_view.content = build_content ();
            split_view.min_sidebar_width = 160;
            split_view.max_sidebar_width = 200;
            split_view.bind_property ("show-sidebar", sidebar_toggle_btn, "active",
                                      GLib.BindingFlags.SYNC_CREATE | GLib.BindingFlags.BIDIRECTIONAL);
            this.content = split_view;

            setup_breakpoints ();

            int init_page = 0;
            string? ipage = GLib.Environment.get_variable ("VECTOR_INITIAL_PAGE");
            if (ipage != null) {
                for (int i = 0; i < PAGES.length; i++) {
                    if (PAGES[i].name == ipage) { init_page = i; break; }
                }
            }
            nav_list.select_row (nav_list.get_row_at_index (init_page));
            if (active_node != null) restore_active_selection ();
            updating_ui = false;
            if (GLib.Environment.get_variable ("VECTOR_SHOW_SIDEBAR") != null) {
                GLib.Timeout.add (500, () => {
                    split_view.show_sidebar = true;
                    return GLib.Source.REMOVE;
                });
            }
            if (GLib.Environment.get_variable ("VECTOR_DEMO_CONNECTED") != null) {
                GLib.Timeout.add (250, () => {
                    setup_demo_connected_state ();
                    return GLib.Source.REMOVE;
                });
            }
        }

        private void setup_demo_connected_state () {
            updating_ui = true;

            int[] demo_latencies = { 18, 25, 34, 48, 72, 95 };
            int[] demo_speeds    = { 85400, 62100, 48300, 31200, 18500, 9200 };
            for (uint i = 0; i < store.nodes.get_n_items (); i++) {
                var node = (Models.Node) store.nodes.get_item (i);
                node.latency = demo_latencies[i % demo_latencies.length];
                node.speed_kbps = demo_speeds[i % demo_speeds.length];
            }

            set_sort ("speed", false);

            if (store.nodes.get_n_items () > 0) {
                var first_node = (Models.Node) store.nodes.get_item (0);
                set_active (first_node);
                restore_active_selection ();
            }

            tun_switch.active = true;
            settings.tun_enabled = true;

            sysproxy_dropdown.selected = 1;
            settings.sysproxy_mode = 1;

            start_button.active = true;
            build_start_button ("Stop", "media-playback-stop-symbolic");
            start_button.remove_css_class ("suggested-action");
            start_button.add_css_class ("destructive-action");
            start_button.child = start_button_content;

            if (active_node != null) {
                active_label.label = active_node.name;
                active_label.remove_css_class ("dim-label");
            }
            ip_label.label = "198.51.100.24 • 18 ms";
            ip_label.remove_css_class ("dim-label");
            country_label.label = "NL";
            country_label.visible = true;

            updating_ui = false;
        }

        private void build_bottom_bar () {
            build_status_box ();
            build_controls_box ();
            bottom_panel = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            bottom_panel.margin_top = 8;
            bottom_panel.margin_bottom = 12;
            bottom_panel.margin_start = 12;
            bottom_panel.margin_end = 12;
            bottom_panel.append (bottom_left_box);
            bottom_panel.append (bottom_right_box);
        }

        private void build_status_box () {
            active_label = new Gtk.Label (active_node != null ? active_node.name : "No server selected");
            active_label.ellipsize = Pango.EllipsizeMode.END;
            if (active_node == null) active_label.add_css_class ("dim-label");
            active_label.halign = Gtk.Align.START;

            ip_label = new Gtk.Label ("Not connected");
            ip_label.ellipsize = Pango.EllipsizeMode.END;
            ip_label.add_css_class ("dim-label");
            ip_label.add_css_class ("caption");
            ip_label.halign = Gtk.Align.START;
            // hide country flag until new IP is resolved
            ip_label.notify["label"].connect (() => { country_label.visible = false; });

            country_label = new Gtk.Label ("");
            country_label.add_css_class ("caption-heading");
            country_label.add_css_class ("dim-label");
            country_label.visible = false;

            var ip_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            ip_row.halign = Gtk.Align.START;
            ip_row.append (country_label);
            ip_row.append (ip_label);

            var info_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            info_box.valign = Gtk.Align.CENTER;
            info_box.append (active_label);
            info_box.append (ip_row);

            info_btn = new Gtk.Button ();
            info_btn.child = info_box;
            info_btn.add_css_class ("flat");
            info_btn.add_css_class ("current-info");
            info_btn.tooltip_text = "Re-check IP and latency";
            info_btn.valign = Gtk.Align.CENTER;
            info_btn.clicked.connect (() => {
                if (active_node != null && runner.running) check_connection_status.begin (true);
            });

            locate_btn = new Gtk.Button.from_icon_name ("target-symbolic");
            locate_btn.tooltip_text = "Locate active server";
            locate_btn.valign = Gtk.Align.CENTER;
            locate_btn.add_css_class ("flat");
            locate_btn.add_css_class ("circular");
            locate_btn.add_css_class ("locate-btn");
            locate_btn.sensitive = active_node != null;
            locate_btn.clicked.connect (locate_active_node);

            bottom_left_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            bottom_left_box.valign = Gtk.Align.CENTER;
            bottom_left_box.hexpand = true;
            bottom_left_box.halign = Gtk.Align.START;
            bottom_left_box.append (info_btn);
            bottom_left_box.append (locate_btn);
        }

        private string start_button_label = "Start";

        private void build_start_button ( string label, string icon = "media-playback-start-symbolic" ) {
            start_button_label = label;
            start_button_content = new Adw.ButtonContent ();
            start_button_content.icon_name = icon;
            // GTK4 CSS cannot collapse label, clear text so Adwaita hides it
            if (start_button.has_css_class ("icon-only")) {
                start_button_content.label = "";
            } else {
                start_button_content.label = label;
            }
        }

        private void build_controls_box () {
            tun_switch = new Gtk.Switch ();
            tun_switch.valign = Gtk.Align.CENTER;
            tun_switch.active = settings.tun_enabled;
            tun_switch.tooltip_text = "TUN mode (system-wide routing)";
            tun_switch.notify["active"].connect (on_tun_switched);

            string[] proxy_modes = { "Clear proxy", "Set proxy", "Off proxy" };
            sysproxy_dropdown = new Gtk.DropDown (Widgets.string_list (proxy_modes), null);
            sysproxy_dropdown.valign = Gtk.Align.CENTER;
            sysproxy_dropdown.selected = settings.sysproxy_mode.clamp (0, 2);
            sysproxy_dropdown.notify["selected"].connect (on_sysproxy_changed);
            // lock width to longest label to prevent dropdown jumping on selection
            sysproxy_dropdown.map.connect (() => { fix_dropdown_width (sysproxy_dropdown, proxy_modes); });

            bottom_controls_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
            bottom_controls_box.append (new Gtk.Label ("TUN"));
            bottom_controls_box.append (tun_switch);
            bottom_controls_box.append (sysproxy_dropdown);

            start_button = new Gtk.ToggleButton ();
            build_start_button ("Start");
            start_button.child = start_button_content;
            start_button.add_css_class ("pill");
            start_button.add_css_class ("suggested-action");
            start_button.add_css_class ("start-button");
            start_button.width_request = 150;
            start_button.height_request = 44;
            start_button.halign = Gtk.Align.FILL;
            start_button.valign = Gtk.Align.CENTER;
            start_button.toggled.connect (on_toggled);

            start_bin = new MatchWidthBin (start_button);
            start_bin.factor = 1.25;

            bottom_right_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
            bottom_right_box.hexpand = true;
            bottom_right_box.halign = Gtk.Align.END;
            bottom_right_box.append (bottom_controls_box);
            bottom_right_box.append (start_bin);
        }

        // TUN switched while connected: reconnect so the router changes.
        private void on_tun_switched () {
            if (updating_ui) return;
            settings.tun_enabled = tun_switch.active;
            settings.save ();
            if (!runner.running) return;
            var n = active_node != null ? active_node : current_selected_node ();
            if (n != null) start_flow_for.begin (n);
        }

        private Gtk.Widget build_sidebar () {
            nav_list = new Gtk.ListBox ();
            nav_list.add_css_class ("navigation-sidebar");
            for (int i = 0; i < PAGES.length; i++) {
                nav_list.append (nav_row (PAGES[i].icon, PAGES[i].title, PAGES[i].name));
            }
            nav_list.row_selected.connect ((lb, row) => {
                if (row == null) return;
                content_stack.visible_child_name = row.name;
                content_title.title = row.get_data<string> ("title");
                update_sort_bar_visibility ();
                if (split_view.collapsed) split_view.show_sidebar = false;
            });
            nav_list.row_activated.connect ((lb, row) => {
                if (row != null && split_view.collapsed) split_view.show_sidebar = false;
            });

            var menu_button = new Gtk.MenuButton ();
            menu_button.icon_name = "open-menu-symbolic";
            menu_button.menu_model = create_app_menu ();
            menu_button.tooltip_text = "Main Menu";

            var header = new Adw.HeaderBar ();
            header.title_widget = new Adw.WindowTitle ("Vector", "");
            header.pack_end (menu_button);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.child = nav_list;

            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (header);
            toolbar.content = scroll;
            return toolbar;
        }

        private Gtk.ListBoxRow nav_row (string icon, string title, string page) {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 6;
            box.margin_end = 6;
            box.append (new Gtk.Image.from_icon_name (icon));
            var label = new Gtk.Label (title);
            label.xalign = 0.0f;
            box.append (label);
            var row = new Gtk.ListBoxRow ();
            row.child = box;
            row.name = page;
            row.set_data<string> ("title", title);
            return row;
        }

        // Header, the page stack (under toasts) and the bottom bars.
        private Gtk.Widget build_content () {
            content_title = new Adw.WindowTitle (PAGES[0].title, "");

            // Shown only while the sidebar is collapsed (narrow window).
            sidebar_toggle_btn = new Gtk.ToggleButton ();
            sidebar_toggle_btn.icon_name = "sidebar-show-symbolic";
            sidebar_toggle_btn.tooltip_text = "Toggle Sidebar";
            sidebar_toggle_btn.visible = false;

            var header = new Adw.HeaderBar ();
            header.title_widget = content_title;
            header.pack_start (sidebar_toggle_btn);

            toast_overlay = new Adw.ToastOverlay ();
            toast_overlay.child = content_stack;
            toast_overlay.vexpand = true;

            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (header);
            toolbar.content = toast_overlay;
            toolbar.add_bottom_bar (servers_sort_wrap);
            toolbar.add_bottom_bar (bottom_panel);
            return toolbar;
        }

        // adwaita breakpoints only fire one at a time, so compact has to duplicate sidebar junk
        private void setup_breakpoints () {
            var bp_medium  = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 849px"));
            var bp_narrow  = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 645px"));
            var bp_compact = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 456px"));
            var bp_mobile  = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 360px"));

            var true_val = GLib.Value (typeof (bool));
            true_val.set_boolean (true);
            var w282 = GLib.Value (typeof (double));
            w282.set_double (282.0);
            foreach (var bp in new Adw.Breakpoint[] { bp_narrow, bp_compact, bp_mobile }) {
                bp.add_setter (split_view, "collapsed", true_val);
                bp.add_setter (sidebar_toggle_btn, "visible", true_val);
                bp.add_setter (split_view, "max-sidebar-width", w282);
                bp.add_setter (split_view, "min-sidebar-width", w282);
            }

            this.notify["current-breakpoint"].connect (() => {
                adapt_bottom_bar (this.current_breakpoint != null,
                    this.current_breakpoint == bp_compact || this.current_breakpoint == bp_mobile);
                set_servers_compact (this.current_breakpoint == bp_compact || this.current_breakpoint == bp_mobile);
            });

            this.add_breakpoint (bp_medium);
            this.add_breakpoint (bp_narrow);
            this.add_breakpoint (bp_compact);
            this.add_breakpoint (bp_mobile);
        }

        private void adapt_bottom_bar (bool two_rows, bool icon_only) {
            if (bottom_panel == null) return;
            bottom_panel.orientation = two_rows ? Gtk.Orientation.VERTICAL : Gtk.Orientation.HORIZONTAL;
            bottom_panel.spacing = two_rows ? 8 : 12;
            bottom_left_box.halign = two_rows ? Gtk.Align.FILL : Gtk.Align.START;
            bottom_right_box.halign = two_rows ? Gtk.Align.FILL : Gtk.Align.END;
            bottom_controls_box.hexpand = two_rows;
            bottom_controls_box.halign = two_rows ? Gtk.Align.START : Gtk.Align.FILL;
            info_btn.hexpand = two_rows;
            info_btn.halign = two_rows ? Gtk.Align.FILL : Gtk.Align.START;
            start_bin.match = two_rows ? bottom_controls_box : null;
            start_button.width_request = icon_only ? 60 : (two_rows ? 120 : 150);
            // collapse label by hand or adwaita leaves blank padding
            if (icon_only) {
                start_button.add_css_class ("icon-only");
                start_button_content.label = "";
            } else {
                start_button.remove_css_class ("icon-only");
                start_button_content.label = start_button_label;
            }
        }

        private static void fix_dropdown_width (Gtk.DropDown dd, string[] labels) {
            if (dd.selected >= labels.length) return;
            dd.width_request = -1;
            int min, nat;
            dd.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            int cur_w = 0, max_w = 0;
            for (int i = 0; i < labels.length; i++) {
                int w, h;
                dd.create_pango_layout (labels[i]).get_pixel_size (out w, out h);
                if (i == (int) dd.selected) cur_w = w;
                max_w = int.max (max_w, w);
            }
            // +4px slack because bold font metrics are cursed
            dd.width_request = nat - cur_w + max_w + 4;
        }

        // UI Helpers

        private delegate void StringSetting (string value);
        private delegate void IntSetting (int value);

        public Gtk.Widget make_sep () {
            var sep = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
            sep.margin_top = 4;
            sep.margin_bottom = 4;
            return sep;
        }

        public Gtk.Popover popover_at (Gtk.Widget anchor, double x, double y, Gtk.Widget content) {
            var popover = new Gtk.Popover ();
            popover.child = content;
            popover.set_parent (anchor);
            var rect = Gdk.Rectangle ();
            rect.x = (int) x;
            rect.y = (int) y;
            rect.width = 1;
            rect.height = 1;
            popover.set_pointing_to (rect);
            return popover;
        }

        public Gtk.Button add_menu_item (Gtk.Box menu, Gtk.Popover popover, string label, owned Ui.Callback action) {
            var btn = make_menu_btn (label);
            btn.clicked.connect (() => {
                popover.popdown ();
                action ();
            });
            menu.append (btn);
            return btn;
        }

        public Gtk.Button make_menu_btn (string label) {
            var btn = new Gtk.Button.with_label (label);
            btn.add_css_class ("flat");
            btn.halign = Gtk.Align.FILL;
            if (btn.child is Gtk.Label) {
                ((Gtk.Label) btn.child).xalign = 0.0f;
            }
            return btn;
        }

        private void show_toast (string message) {
            var toast = new Adw.Toast (message);
            toast.timeout = 4;
            toast_overlay.add_toast (toast);
        }

        // Auto-updates

        private void setup_auto_update_timer () {
            GLib.Timeout.add_seconds (60, () => {
                check_and_run_auto_updates.begin ();
                return GLib.Source.CONTINUE;
            });
        }

        private bool auto_updating = false;

        private async void check_and_run_auto_updates () {
            if (auto_updating) return; // previous tick still downloading
            auto_updating = true;
            int64 now = GLib.get_real_time () / 1000000;
            yield auto_update_groups ();

            if (settings.geo_update_interval > 0) {
                int64 geo_interval_sec = (int64) settings.geo_update_interval * 3600;
                if ((now - settings.geo_last_update) >= geo_interval_sec) {
                    settings.geo_last_update = now; // stamp it even if it failed so we dont spam downloads on every restart
                    settings.save ();
                    append_log ("[auto-update] Starting auto-update for Geo assets...");
                    try {
                        string msg = yield geo_mgr.update (routing_core (), settings, store);
                        append_log ("[auto-update] " + msg);
                    } catch (GLib.Error e) {
                        append_log ("[auto-update] Geo update failed: %s".printf (e.message));
                    }
                }
            }
            auto_updating = false;
        }

        // App Menu & About Dialog

        private GLib.Menu create_app_menu () {
            var menu = new GLib.Menu ();
            menu.append ("About Vector", "app.about");
            var exit_section = new GLib.Menu ();
            exit_section.append ("Full Exit", "app.full-exit");
            menu.append_section (null, exit_section);
            return menu;
        }

        public void show_about () {
            var about = new Adw.AboutDialog ();
            about.application_name = "Vector";
            about.application_icon = "io.github.dp0sk.Vector";
            about.version = Config.APP_VERSION;
            about.developer_name = "dp0sk";
            about.website = "https://github.com/dp0sk/Vector";
            about.issue_url = "https://github.com/dp0sk/Vector/issues";
            about.license_type = Gtk.License.GPL_3_0_ONLY;
            about.copyright = "© 2026 dp0sk";
            about.present (this);
        }

    }
}
