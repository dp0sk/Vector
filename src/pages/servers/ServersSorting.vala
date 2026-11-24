using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private string current_sort_col = "default";
        private bool current_sort_asc = true;
        private Gtk.CustomSorter? current_sorter = null;
        private uint sort_throttle_id = 0;
        private Gtk.Image col_name_arrow;
        private Gtk.Image col_ping_arrow;
        private Gtk.Image col_speed_arrow;
        private Gtk.Button col_name_btn;
        private Gtk.Button col_ping_btn;
        private Gtk.Button col_speed_btn;
        private Gtk.PopoverMenu? sort_popover = null;

        private Gtk.Box servers_sort_bar;
        // bottom bar in toolbarview so toasts pop up above it
        private Gtk.Widget servers_sort_wrap;
        private Adw.ToggleGroup sort_toggles;
        private Gtk.Button sort_dir_btn;
        private bool servers_compact = false;

        // narrow layout sort bar: Name/Ping/Speed, direction arrow, and reparented test buttons
        private Gtk.Widget build_sort_bar () {
            sort_toggles = new Adw.ToggleGroup ();
            foreach (var col in new string[] { "name", "ping", "speed" }) {
                var t = new Adw.Toggle ();
                t.name = col;
                t.label = col == "name" ? "Name" : (col == "ping" ? "Ping" : "Speed");
                sort_toggles.add (t);
            }
            sort_toggles.valign = Gtk.Align.CENTER;
            sort_toggles.notify["active-name"].connect (() => {
                if (updating_ui) return;
                string? col = sort_toggles.active_name;
                if (col != null && col != current_sort_col) {
                    set_sort (col, col != "speed"); // speed: fastest first
                }
            });

            sort_dir_btn = new Gtk.Button ();
            sort_dir_btn.add_css_class ("circular");
            sort_dir_btn.add_css_class ("sort-dir-btn");
            sort_dir_btn.valign = Gtk.Align.CENTER;
            sort_dir_btn.clicked.connect (() => {
                if (current_sort_col != "default") set_sort (current_sort_col, !current_sort_asc);
            });

            var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;

            servers_sort_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            servers_sort_bar.margin_start = 12;
            servers_sort_bar.margin_end = 6;
            servers_sort_bar.margin_top = 6;
            servers_sort_bar.margin_bottom = 6;
            servers_sort_bar.append (sort_toggles);
            servers_sort_bar.append (sort_dir_btn);
            servers_sort_bar.append (spacer);

            var rclick = new Gtk.GestureClick ();
            rclick.button = 3;
            rclick.pressed.connect ((n_press, x, y) => {
                show_sort_context_menu (servers_sort_bar, x, y);
            });
            servers_sort_bar.add_controller (rclick);

            var sep = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
            var wrap = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            wrap.append (sep);
            wrap.append (servers_sort_bar);
            wrap.visible = false;
            return wrap;
        }

        // narrow layout swap: move test buttons and toggle compact row metrics
        private void set_servers_compact (bool compact) {
            if (servers_sort_bar == null || compact == servers_compact) return;
            servers_compact = compact;
            Gtk.Box from = compact ? servers_topbar : servers_sort_bar;
            Gtk.Box to = compact ? servers_sort_bar : servers_topbar;
            from.remove (bench_ping_btn);
            from.remove (bench_speed_btn);
            to.append (bench_ping_btn);
            to.append (bench_speed_btn);
            servers_header_bar.visible = !compact;
            update_sort_bar_visibility ();
            NodeRowLayout.get_default ().compact = compact;
        }

        private void update_sort_bar_visibility () {
            if (servers_sort_wrap == null) return;
            servers_sort_wrap.visible = servers_compact && content_stack.visible_child_name == "servers";
        }

        private Gtk.Box build_column_header () {
            col_name_btn = create_header_col ("Name", out col_name_arrow, Gtk.Align.START, -1, true);
            col_name_btn.clicked.connect (() => { on_column_header_clicked ("name"); });
            col_ping_btn = create_header_col ("Ping", out col_ping_arrow, Gtk.Align.END, 80, false);
            col_ping_btn.clicked.connect (() => { on_column_header_clicked ("ping"); });
            col_speed_btn = create_header_col ("Speed", out col_speed_arrow, Gtk.Align.END, 90, false);
            col_speed_btn.clicked.connect (() => { on_column_header_clicked ("speed"); });

            var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            header.margin_start = 20;
            header.margin_end = 20;
            header.margin_top = 4;
            header.margin_bottom = 2;
            header.add_css_class ("server-header-bar");
            header.append (col_name_btn);
            header.append (col_ping_btn);
            header.append (col_speed_btn);

            var right_click = new Gtk.GestureClick ();
            right_click.button = 3;
            right_click.pressed.connect ((n_press, x, y) => { show_sort_context_menu (header, x, y); });
            header.add_controller (right_click);
            return header;
        }

        private void load_sort_state () {
            current_sort_col = settings.sort_column;
            if (current_sort_col != "name" && current_sort_col != "ping" && current_sort_col != "speed") {
                current_sort_col = "default";
            }
            current_sort_asc = settings.sort_asc;
            if (current_sort_col != "default") {
                current_sorter = new Gtk.CustomSorter ((a, b) => compare_nodes ((GLib.Object) a, (GLib.Object) b));
            }
            update_sort_header_ui ();
        }

        private Gtk.Button create_header_col (string title, out Gtk.Image arrow_img, Gtk.Align align, int width = -1, bool hexpand = false) {
            var btn = new Gtk.Button ();
            btn.add_css_class ("flat");
            btn.add_css_class ("server-col-btn");

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            box.halign = align;

            var title_lbl = new Gtk.Label (title);
            title_lbl.add_css_class ("col-title");

            arrow_img = new Gtk.Image ();
            arrow_img.add_css_class ("col-arrow");
            arrow_img.visible = false;

            // right-aligned columns put arrow BEFORE title so showing/hiding arrow doesn't jitter label position
            if (align == Gtk.Align.END) {
                box.append (arrow_img);
                box.append (title_lbl);
            } else {
                box.append (title_lbl);
                box.append (arrow_img);
            }

            btn.child = box;
            if (width > 0) btn.width_request = width;
            btn.hexpand = hexpand;

            return btn;
        }

        private void on_column_header_clicked (string col) {
            if (current_sort_col == col) {
                set_sort (col, !current_sort_asc);
            } else {
                set_sort (col, col != "speed"); // speed: fastest first
            }
        }

        private void set_sort (string col_in, bool asc) {
            // local copy because callers might pass current_sort_col itself (which gets freed on reassign)
            string col = col_in;
            current_sort_col = col;
            current_sort_asc = asc;

            settings.sort_column = col;
            settings.sort_asc = asc;
            settings.save ();

            update_sort_header_ui ();

            if (col == "default") {
                current_sorter = null;
            } else {
                current_sorter = new Gtk.CustomSorter ((a, b) => compare_nodes ((GLib.Object) a, (GLib.Object) b));
            }

            apply_sort_to_all_tabs ();
        }

        private void update_sort_header_ui () {
            if (sort_toggles != null) {
                bool prev = updating_ui;
                updating_ui = true;
                if (current_sort_col == "default") {
                    sort_toggles.active = Gtk.INVALID_LIST_POSITION;
                } else {
                    sort_toggles.active_name = current_sort_col;
                }
                updating_ui = prev;
                sort_dir_btn.icon_name = current_sort_asc ? "pan-up-symbolic" : "pan-down-symbolic";
                sort_dir_btn.tooltip_text = current_sort_asc ? "Ascending" : "Descending";
                sort_dir_btn.sensitive = current_sort_col != "default";
            }
            col_name_arrow.visible = false;
            col_ping_arrow.visible = false;
            col_speed_arrow.visible = false;

            col_name_btn.remove_css_class ("active-sort");
            col_ping_btn.remove_css_class ("active-sort");
            col_speed_btn.remove_css_class ("active-sort");

            string icon_name = current_sort_asc ? "pan-up-symbolic" : "pan-down-symbolic";

            if (current_sort_col == "name") {
                col_name_arrow.icon_name = icon_name;
                col_name_arrow.visible = true;
                col_name_btn.add_css_class ("active-sort");
            } else if (current_sort_col == "ping") {
                col_ping_arrow.icon_name = icon_name;
                col_ping_arrow.visible = true;
                col_ping_btn.add_css_class ("active-sort");
            } else if (current_sort_col == "speed") {
                col_speed_arrow.icon_name = icon_name;
                col_speed_arrow.visible = true;
                col_speed_btn.add_css_class ("active-sort");
            }
        }

        private void apply_sort_to_all_tabs () {
            for (int p = 0; p < server_tabs.n_pages; p++) {
                var page = server_tabs.get_nth_page (p);
                if (page == null || page.child == null) continue;
                var sm = page.child.get_data<Gtk.SortListModel> ("sort_model");
                if (sm != null) {
                    sm.sorter = current_sorter;
                }
            }
            restore_active_selection ();
        }

        private int compare_nodes (GLib.Object item_a, GLib.Object item_b) {
            var a = (Models.Node) item_a;
            var b = (Models.Node) item_b;

            if (current_sort_col == "name") {
                string ga = a.group_name != "" ? a.group_name : store.get_node_group_name (a);
                string gb = b.group_name != "" ? b.group_name : store.get_node_group_name (b);
                int cmp = ga.casefold ().collate (gb.casefold ());
                if (cmp == 0) cmp = a.name.casefold ().collate (b.name.casefold ());
                if (cmp == 0) cmp = (int) a.orig_index - (int) b.orig_index;
                return current_sort_asc ? cmp : -cmp;
            }

            if (current_sort_col == "ping") {
                bool a_valid = (a.latency > 0);
                bool b_valid = (b.latency > 0);

                if (a_valid && b_valid) {
                    int diff = a.latency - b.latency;
                    if (diff != 0) return current_sort_asc ? diff : -diff;
                    return (int) a.orig_index - (int) b.orig_index;
                }
                if (a_valid && !b_valid) return -1;
                if (!a_valid && b_valid) return 1;

                if (a.latency != b.latency) return a.latency < b.latency ? -1 : 1;
                return (int) a.orig_index - (int) b.orig_index;
            }

            if (current_sort_col == "speed") {
                bool a_valid = (a.speed_kbps > 0);
                bool b_valid = (b.speed_kbps > 0);

                if (a_valid && b_valid) {
                    int diff = a.speed_kbps - b.speed_kbps;
                    if (diff != 0) return current_sort_asc ? diff : -diff;
                    return (int) a.orig_index - (int) b.orig_index;
                }
                // Untested / failed nodes always go last.
                if (a_valid && !b_valid) return -1;
                if (!a_valid && b_valid) return 1;
                return (int) a.orig_index - (int) b.orig_index;
            }

            // stable sort tiebreaker: fallback to orig_index so rows don't randomly flip-flop when ping/speed is identical
            return (int) a.orig_index - (int) b.orig_index;
        }

        private void show_sort_context_menu (Gtk.Widget target, double x, double y) {
            if (sort_popover == null) {
                var menu = new GLib.Menu ();
                menu.append ("Reset sort to default", "win.sort_default");
                var sec = new GLib.Menu ();
                sec.append ("Sort by Name", "win.sort_name");
                sec.append ("Sort by Ping", "win.sort_ping");
                sec.append ("Sort by Speed", "win.sort_speed");
                menu.append_section (null, sec);

                var act_def = new GLib.SimpleAction ("sort_default", null);
                act_def.activate.connect (() => {
                    set_sort ("default", true);
                    show_toast ("Sort reset to default subscription order.");
                });
                this.add_action (act_def);

                var act_n = new GLib.SimpleAction ("sort_name", null);
                act_n.activate.connect (() => { on_column_header_clicked ("name"); });
                this.add_action (act_n);

                var act_p = new GLib.SimpleAction ("sort_ping", null);
                act_p.activate.connect (() => { on_column_header_clicked ("ping"); });
                this.add_action (act_p);

                var act_s = new GLib.SimpleAction ("sort_speed", null);
                act_s.activate.connect (() => { on_column_header_clicked ("speed"); });
                this.add_action (act_s);

                sort_popover = new Gtk.PopoverMenu.from_model (menu);
                sort_popover.set_parent (target);
                sort_popover.has_arrow = false;
            } else if (sort_popover.get_parent () != target) {
                sort_popover.unparent ();
                sort_popover.set_parent (target);
            }
            var rect = Gdk.Rectangle ();
            rect.x = (int) x;
            rect.y = (int) y;
            rect.width = 1;
            rect.height = 1;
            sort_popover.set_pointing_to (rect);
            sort_popover.popup ();
        }

        // GtkSortListModel + GtkListView scroll jump hell:
        // when test results stream in and we call sorter.changed(), GTK re-orders items and randomly yeets the scroll position.
        // We snapshot vadjustment values, restore right away, AND schedule an idle callback to restore again after GTK's async layout pass finishes its tantrum.
        public void schedule_dynamic_sort () {
            if (current_sorter == null || (current_sort_col != "ping" && current_sort_col != "speed")) return;
            if (sort_throttle_id != 0) return;

            sort_throttle_id = GLib.Timeout.add (100, () => {
                sort_throttle_id = 0;
                if (current_sorter != null) {
                    var scroll_vals = new GLib.GenericArray<double?> ();
                    for (int p = 0; p < server_tabs.n_pages; p++) {
                        var page = server_tabs.get_nth_page (p);
                        var sw = (page != null) ? page.child as Gtk.ScrolledWindow : null;
                        if (sw != null && sw.vadjustment != null) {
                            scroll_vals.add (sw.vadjustment.value);
                        } else {
                            scroll_vals.add (null);
                        }
                    }

                    current_sorter.changed (Gtk.SorterChange.DIFFERENT);
                    restore_active_selection ();

                    void restore_scroll_positions () {
                        for (int p = 0; p < server_tabs.n_pages; p++) {
                            var val = scroll_vals.get (p);
                            if (val != null) {
                                var page = server_tabs.get_nth_page (p);
                                var sw = (page != null) ? page.child as Gtk.ScrolledWindow : null;
                                if (sw != null && sw.vadjustment != null) {
                                    sw.vadjustment.value = val;
                                }
                            }
                        }
                    }

                    restore_scroll_positions ();
                    GLib.Idle.add (() => {
                        restore_scroll_positions ();
                        return GLib.Source.REMOVE;
                    });
                }
                return GLib.Source.REMOVE;
            });
        }

        public void refresh_sorting () {
            if (current_sort_col != "default") {
                current_sorter = new Gtk.CustomSorter ((a, b) => compare_nodes ((GLib.Object) a, (GLib.Object) b));
                apply_sort_to_all_tabs ();
            }
        }
    }
}
