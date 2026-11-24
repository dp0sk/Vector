using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {

    private class LogEntry : GLib.Object {
        public string raw;
        public string clean;
        public string category; // "app", "core", "inbound", "outbound"
        public string level;    // "info", "warn", "error", "debug"

        public LogEntry (string raw_line, string clean_line, string cat, string lvl) {
            raw = raw_line;
            clean = clean_line;
            category = cat;
            level = lvl;
        }
    }

    public partial class MainWindow {

        private const uint MAX_LOG_ENTRIES = 2000;
        private Gtk.TextView log_view;
        // GtkTextTag doesn't do CSS stylesheets. We create invisible probe labels with .log-* classes and steal their RGBA colors.
        private GLib.HashTable<string, Gtk.Label> log_color_probes =
            new GLib.HashTable<string, Gtk.Label> (str_hash, str_equal);
        private GLib.ListStore log_store = new GLib.ListStore (typeof (LogEntry));

        // filter button defs (category/level -> label, icon, css class)
        private class LogFilterDef {
            public string key;
            public string label;
            public string icon;
            public string css; // empty = default fg color
            public LogFilterDef (string key, string label, string icon, string css) {
                this.key = key;
                this.label = label;
                this.icon = icon;
                this.css = css;
            }
        }
        private LogFilterDef[] LOG_CATEGORY_FILTERS = {
            new LogFilterDef ("app",      "App",      "3d-box-symbolic",                 "log-app"),
            new LogFilterDef ("core",     "Core",     "application-x-sharedlib-symbolic", ""),
            new LogFilterDef ("inbound",  "Inbound",  "base-down-arrow-symbolic",         "log-inbound"),
            new LogFilterDef ("outbound", "Outbound", "base-up-arrow-symbolic",           "log-outbound")
        };
        private LogFilterDef[] LOG_LEVEL_FILTERS = {
            new LogFilterDef ("info",  "Logs",     "info-outline-symbolic",   ""),
            new LogFilterDef ("warn",  "Warnings", "mark-junk-symbolic",      "log-warn"),
            new LogFilterDef ("error", "Errors",   "bug-symbolic",            "log-error")
        };
        // disabled filter tags
        private GLib.HashTable<string, bool> log_hidden = new GLib.HashTable<string, bool> (str_hash, str_equal);
        private string log_search_text = "";

        // auto-scroll state: tricky as hell because GtkTextView measures lines asynchronously, constantly jittering vadjustment.
        // we track actual user interaction (wheel, key, scrollbar drag) so layout engine spasms don't kill auto-follow.
        private bool log_follow = true;
        private Gtk.Adjustment log_vadj;
        private Gtk.Revealer log_bottom_revealer;
        private bool log_rebuilding = false; // refilling buffer moves adjustment, ignore that
        private bool log_pinning = false;    // internal scroll-to-bottom flag
        private int64 log_user_scroll_until = 0;
        private bool log_scrollbar_dragging = false;

        private static GLib.Regex? ansi_re = null;
        static construct {
            try {
                ansi_re = new GLib.Regex ("\x1b\\[[0-9;]*m");
            } catch (GLib.Error e) {}
        }

        private static string strip_ansi (string s) {
            if (ansi_re == null) return s;
            string result = s;
            try {
                result = ansi_re.replace (s, -1, 0, "");
            } catch (GLib.Error e) {}
            return result;
        }

        private static bool is_hms (string s, int at) {
            if (s.length < at + 8) return false;
            for (int j = 0; j < 8; j++) {
                char c = s[at + j];
                if (j == 2 || j == 5) { if (c != ':') return false; }
                else if (c < '0' || c > '9') return false;
            }
            return true;
        }

        // timestamp length prefix ("HH:MM:SS " or sing-box raw datetime), 0 if none
        private static int find_timestamp_end (string s) {
            if (is_hms (s, 0)) return s.length > 8 && s[8] == ' ' ? 9 : 8;
            return find_raw_timestamp_end (s);
        }

        private static int find_raw_timestamp_end (string s) {
            // Match: +/-HHMM YYYY-MM-DD HH:MM:SS
            int i = 0;
            // timezone: +/- and 4 digits
            if (s.length < 5) return 0;
            if (s[0] != '+' && s[0] != '-') return 0;
            for (i = 1; i < 5; i++) {
                if (s[i] < '0' || s[i] > '9') return 0;
            }
            // space
            if (s[i] != ' ') return i;
            i++;
            // date: YYYY-MM-DD
            for (int j = 0; j < 10 && i < (int) s.length; j++, i++) {
                if (j == 4 || j == 7) {
                    if (s[i] != '-') return i;
                } else {
                    if (s[i] < '0' || s[i] > '9') return i;
                }
            }
            // space
            if (i < (int) s.length && s[i] == ' ') i++;
            // time: HH:MM:SS
            for (int j = 0; j < 8 && i < (int) s.length; j++, i++) {
                if (j == 2 || j == 5) {
                    if (s[i] != ':') return i;
                } else {
                    if (s[i] < '0' || s[i] > '9') return i;
                }
            }
            // trailing space
            if (i < (int) s.length && s[i] == ' ') i++;
            return i;
        }

        private static string detect_category (string clean) {
            if (clean.has_prefix ("[app]") || clean.has_prefix ("[auto-update]"))
                return "app";
            if (clean.contains ("inbound/"))
                return "inbound";
            if (clean.contains ("outbound/"))
                return "outbound";
            return "core";
        }

        private static string detect_level (string clean) {
            string lower = clean.down ();
            if (lower.contains ("error") || lower.contains ("fatal"))
                return "error";
            if (lower.contains ("warn"))
                return "warn";
            if (lower.contains ("debug"))
                return "debug";
            return "info";
        }

        private Gtk.Widget build_log_page () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (build_log_top_bar ());
            box.append (build_log_area ());
            return box;
        }

        private Gtk.Widget build_log_top_bar () {
            var search_entry = new Gtk.SearchEntry ();
            search_entry.placeholder_text = "Search logs\u2026";
            search_entry.hexpand = true;
            search_entry.changed.connect (() => {
                log_search_text = search_entry.text.down ();
                rebuild_log_view ();
            });

            var filter_btn = new Gtk.MenuButton ();
            filter_btn.icon_name = "sliders-symbolic";
            filter_btn.tooltip_text = "Filters";
            filter_btn.add_css_class ("flat");
            filter_btn.popover = build_filter_popover ();

            var clear_btn = Widgets.icon_button ("eraser-symbolic", "Clear log");
            clear_btn.clicked.connect (() => {
                log_store.remove_all ();
                log_view.buffer.set_text ("", -1);
                set_log_follow (true);
            });

            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            bar.margin_top = 6;
            bar.margin_bottom = 6;
            bar.margin_start = 10;
            bar.margin_end = 10;
            bar.append (search_entry);
            bar.append (filter_btn);
            bar.append (clear_btn);
            return bar;
        }

        private Gtk.Popover build_filter_popover () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 14;
            box.margin_end = 14;
            box.append (popover_heading ("Categories"));
            box.append (build_filter_buttons (LOG_CATEGORY_FILTERS));
            box.append (popover_heading ("Levels"));
            box.append (build_filter_buttons (LOG_LEVEL_FILTERS));
            box.append (popover_heading ("View"));
            box.append (build_view_options ());

            var popover = new Gtk.Popover ();
            popover.child = box;
            return popover;
        }

        private static Gtk.Label popover_heading (string text) {
            var label = new Gtk.Label (text);
            label.halign = Gtk.Align.START;
            label.add_css_class ("heading");
            return label;
        }

        private Adw.WrapBox build_filter_buttons (LogFilterDef[] filters) {
            var wrap = new Adw.WrapBox ();
            wrap.child_spacing = 6;
            wrap.line_spacing = 6;
            foreach (var f in filters) {
                string key = f.key;
                // Adw.ButtonContent needed because setting icon or label wipes button child
                var content = new Adw.ButtonContent ();
                content.label = f.label;
                content.icon_name = f.icon;
                var btn = new Gtk.ToggleButton ();
                btn.child = content;
                btn.active = !log_hidden.contains (key);
                btn.add_css_class ("log-filter");
                if (f.css != "") btn.add_css_class (f.css);
                btn.toggled.connect (() => {
                    if (btn.active) log_hidden.remove (key);
                    else log_hidden.insert (key, true);
                    rebuild_log_view ();
                });
                wrap.append (btn);
            }
            return wrap;
        }

        private Gtk.Widget build_view_options () {
            var wrap_check = new Gtk.CheckButton.with_label ("Wrap lines");
            wrap_check.active = settings.log_wrap;
            wrap_check.toggled.connect (() => {
                settings.log_wrap = wrap_check.active;
                settings.save ();
                apply_log_wrap ();
                if (log_follow) scroll_log_to_end ();
            });

            var time_check = new Gtk.CheckButton.with_label ("Show time");
            time_check.active = settings.log_show_time;
            time_check.toggled.connect (() => {
                settings.log_show_time = time_check.active;
                settings.save ();
                rebuild_log_view ();
            });

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            box.append (wrap_check);
            box.append (time_check);
            return box;
        }

        private void apply_log_wrap () {
            log_view.wrap_mode = settings.log_wrap ? Gtk.WrapMode.WORD_CHAR : Gtk.WrapMode.NONE;
        }

        // text view with jump-to-bottom button and CSS color probe overlays
        private Gtk.Widget build_log_area () {
            log_view = new Gtk.TextView ();
            log_view.monospace = true;
            log_view.editable = false;
            log_view.cursor_visible = false;
            log_view.top_margin = 4;
            log_view.bottom_margin = 4;
            log_view.left_margin = 10;
            log_view.right_margin = 10;
            apply_log_wrap ();
            setup_log_tags ();

            var scroll = new Gtk.ScrolledWindow ();
            scroll.child = log_view;
            scroll.vexpand = true;
            scroll.hexpand = true;
            setup_log_follow (scroll);

            var bottom_btn = new Gtk.Button.from_icon_name ("go-bottom-symbolic");
            bottom_btn.tooltip_text = "Scroll to bottom";
            bottom_btn.add_css_class ("osd");
            bottom_btn.add_css_class ("circular");
            bottom_btn.clicked.connect (() => {
                set_log_follow (true);
                scroll_log_to_end ();
            });
            log_bottom_revealer = new Gtk.Revealer ();
            log_bottom_revealer.transition_type = Gtk.RevealerTransitionType.CROSSFADE;
            log_bottom_revealer.child = bottom_btn;
            log_bottom_revealer.halign = Gtk.Align.END;
            log_bottom_revealer.valign = Gtk.Align.END;
            log_bottom_revealer.margin_end = 18;
            log_bottom_revealer.margin_bottom = 12;
            log_bottom_revealer.reveal_child = false;

            var overlay = new Gtk.Overlay ();
            overlay.child = scroll;
            overlay.add_overlay (build_color_probes ());
            overlay.add_overlay (log_bottom_revealer);
            return overlay;
        }

        // only user-initiated scrolling (wheel, keys, scrollbar drag) should break auto-follow
        private void setup_log_follow (Gtk.ScrolledWindow scroll) {
            log_vadj = scroll.vadjustment;
            // value_changed tracks user position; text layout happens asynchronously later and grows upper, so pin on changed
            log_vadj.value_changed.connect (on_log_scrolled);
            log_vadj.changed.connect (() => {
                if (log_follow && !log_rebuilding) pin_log_to_bottom ();
            });

            var wheel = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.VERTICAL);
            wheel.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            wheel.scroll.connect ((dx, dy) => { mark_log_user_scroll (); return false; });
            scroll.add_controller (wheel);

            var keys = new Gtk.EventControllerKey ();
            keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            keys.key_pressed.connect ((keyval, keycode, state) => { mark_log_user_scroll (); return false; });
            log_view.add_controller (keys);

            var drag = new Gtk.GestureClick ();
            drag.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            drag.begin.connect (() => { log_scrollbar_dragging = true; });
            drag.end.connect (() => { log_scrollbar_dragging = false; });
            drag.cancel.connect (() => { log_scrollbar_dragging = false; });
            scroll.get_vscrollbar ().add_controller (drag);
        }

        // opacity 0 keeps probe labels styled by GTK CSS without rendering; visible=false would kill CSS styling completely!
        private Gtk.Widget build_color_probes () {
            var probes = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            probes.opacity = 0;
            probes.can_target = false;
            probes.halign = Gtk.Align.START;
            probes.valign = Gtk.Align.START;
            foreach (var cls in LOG_COLOR_CLASSES) {
                var probe = new Gtk.Label ("");
                probe.add_css_class (cls);
                probes.append (probe);
                log_color_probes.insert (cls, probe);
            }
            log_view.map.connect (refresh_log_tag_colors);
            var style = Adw.StyleManager.get_default ();
            style.notify["dark"].connect (queue_log_tag_colors);
            style.notify["high-contrast"].connect (queue_log_tag_colors);
            return probes;
        }

        // CSS classes synced between log tags and filter buttons
        private const string[] LOG_COLOR_CLASSES = {
            "log-dim", "log-debug", "log-warn", "log-error", "log-app", "log-inbound", "log-outbound"
        };

        private void setup_log_tags () {
            var buf = log_view.buffer;
            foreach (var cls in LOG_COLOR_CLASSES) buf.create_tag (cls);
            buf.create_tag ("log-info");
            buf.tag_table.lookup ("log-error").weight = Pango.Weight.BOLD;
        }

        private void refresh_log_tag_colors () {
            var table = log_view.buffer.tag_table;
            log_color_probes.foreach ((cls, probe) => {
                var tag = table.lookup (cls);
                if (tag != null) tag.foreground_rgba = probe.get_color ();
            });
        }

        // queue tag update on idle after theme flip so GTK finishes restyling first
        private void queue_log_tag_colors () {
            GLib.Idle.add (() => {
                refresh_log_tag_colors ();
                return GLib.Source.REMOVE;
            });
        }

        private string choose_body_tag (string category, string level) {
            if (category == "app")      return "log-app";
            if (category == "inbound")  return "log-inbound";
            if (category == "outbound") return "log-outbound";

            switch (level) {
                case "error": return "log-error";
                case "warn":  return "log-warn";
                case "debug": return "log-debug";
                default:      return "log-info";
            }
        }

        // VECTOR_LOG_STDOUT=1 also dumps to stdout for headless runs
        private static int log_stdout = -1;

        public void append_log (string line) {
            if (log_stdout < 0) log_stdout = GLib.Environment.get_variable ("VECTOR_LOG_STDOUT") == "1" ? 1 : 0;
            if (log_stdout == 1) {
                stdout.printf ("LOG %s\n", line);
                stdout.flush ();
            }
            string clean = strip_ansi (line);
            string category = detect_category (clean);
            string level = detect_level (clean);

            var entry = new LogEntry (line, clean, category, level);
            if (log_store.get_n_items () >= MAX_LOG_ENTRIES) {
                log_store.remove (0);
            }
            log_store.append (entry);

            if (pass_filter (entry.category, entry.level) && pass_search (entry.clean)) {
                append_log_entry (entry);
                if (log_follow) scroll_log_to_end ();
            }
        }

        // debug lines lumped under "info" toggle
        private bool pass_filter (string category, string level) {
            string level_key = level == "debug" ? "info" : level;
            return !log_hidden.contains (category) && !log_hidden.contains (level_key);
        }

        private void append_log_entry (LogEntry entry) {
            var buffer = log_view.buffer;
            if (buffer.get_line_count () > (int) MAX_LOG_ENTRIES) {
                Gtk.TextIter start_it, line_end_it;
                buffer.get_start_iter (out start_it);
                line_end_it = start_it;
                // ring buffer trim: don't let view jump under user's feet if they're reading old logs
                int y, height;
                log_view.get_line_yrange (start_it, out y, out height);
                if (line_end_it.forward_line ()) {
                    buffer.delete (ref start_it, ref line_end_it);
                    if (!log_follow && log_vadj != null) {
                        log_vadj.value = double.max (0, log_vadj.value - height);
                    }
                }
            }

            Gtk.TextIter iter;
            buffer.get_end_iter (out iter);

            string body_tag = choose_body_tag (entry.category, entry.level);

            int ts_end = find_timestamp_end (entry.clean);
            if (ts_end > 0 && !settings.log_show_time) {
                buffer.insert_with_tags_by_name (ref iter, entry.clean.substring (ts_end), -1, body_tag);
            } else if (ts_end > 0) {
                buffer.insert_with_tags_by_name (ref iter, entry.clean.substring (0, ts_end), -1, "log-dim");
                buffer.insert_with_tags_by_name (ref iter, entry.clean.substring (ts_end), -1, body_tag);
            } else {
                buffer.insert_with_tags_by_name (ref iter, entry.clean, -1, body_tag);
            }
            buffer.insert (ref iter, "\n", -1);
        }

        private void mark_log_user_scroll () {
            log_user_scroll_until = GLib.get_monotonic_time () + 400000; // 0.4 s
        }

        private void on_log_scrolled () {
            if (log_rebuilding || log_pinning) return;
            bool at_bottom = log_vadj.value >= log_vadj.upper - log_vadj.page_size - 8.0;
            bool by_user = log_scrollbar_dragging || GLib.get_monotonic_time () < log_user_scroll_until;
            if (at_bottom) set_log_follow (true);
            else if (by_user) set_log_follow (false);
            else if (log_follow) pin_log_to_bottom (); // the view moved itself
        }

        private void set_log_follow (bool follow) {
            log_follow = follow;
            if (log_bottom_revealer != null) log_bottom_revealer.reveal_child = !follow;
        }

        private void pin_log_to_bottom () {
            log_pinning = true;
            log_vadj.value = log_vadj.upper - log_vadj.page_size;
            log_pinning = false;
        }

        // snap to bottom now; pending layout passes will follow via vadj.changed
        private void scroll_log_to_end () {
            if (log_vadj != null) pin_log_to_bottom ();
        }

        private void rebuild_log_view () {
            log_rebuilding = true;
            log_view.buffer.set_text ("", -1);
            uint n = log_store.get_n_items ();
            for (uint i = 0; i < n; i++) {
                var entry = (LogEntry) log_store.get_item (i);
                if (pass_filter (entry.category, entry.level) && pass_search (entry.clean)) {
                    append_log_entry (entry);
                }
            }
            log_rebuilding = false;
            if (log_follow) scroll_log_to_end ();
        }

        private bool pass_search (string clean) {
            if (log_search_text.length == 0) return true;
            return clean.down ().contains (log_search_text);
        }
    }
}
