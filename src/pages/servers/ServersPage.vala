using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {

    public partial class MainWindow {

        private Adw.TabView server_tabs;
        private bool allow_tab_close = false;
        private GLib.GenericArray<Gtk.ListView> server_views = new GLib.GenericArray<Gtk.ListView> ();
        private Gtk.Box servers_topbar;
        private Gtk.Box servers_header_bar;


        private Gtk.Widget build_servers_page () {
            register_add_actions ();
            build_server_tabs ();
            servers_header_bar = build_column_header ();
            servers_sort_wrap = build_sort_bar ();
            load_sort_state ();

            var sep = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
            sep.add_css_class ("server-header-sep");

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (build_servers_top_bar ());
            box.append (servers_header_bar);
            box.append (sep);
            box.append (server_tabs);

            var paste_keys = new Gtk.EventControllerKey ();
            paste_keys.key_pressed.connect ((keyval, keycode, state) => {
                if (keyval != Gdk.Key.v || (state & Gdk.ModifierType.CONTROL_MASK) == 0) return false;
                handle_paste ();
                return true;
            });
            box.add_controller (paste_keys);

            rebuild_server_tabs ();
            return box;
        }

        private void register_add_actions () {
            var import_clip = new GLib.SimpleAction ("import_clipboard", null);
            import_clip.activate.connect (() => { handle_paste (); });
            add_action (import_clip);

            var import_wg = new GLib.SimpleAction ("import_wg_file", null);
            import_wg.activate.connect (() => { import_wg_file.begin (); });
            add_action (import_wg);

            var new_group = new GLib.SimpleAction ("new_sub_group", null);
            new_group.activate.connect (() => { show_group_dialog (null); });
            add_action (new_group);

            var new_node = new GLib.SimpleAction ("new_node", GLib.VariantType.STRING);
            new_node.activate.connect ((action, param) => { handle_new_manual_node (param.get_string ()); });
            add_action (new_node);
        }

        private Gtk.Widget build_servers_top_bar () {
            var node_menu = new GLib.Menu ();
            foreach (string protocol in new string[] { "vless", "vmess", "shadowsocks", "trojan", "socks", "http", "awg" }) {
                var item = new GLib.MenuItem (protocol, null);
                item.set_action_and_target_value ("win.new_node", new GLib.Variant.string (protocol));
                node_menu.append_item (item);
            }
            var add_menu = new GLib.Menu ();
            add_menu.append ("Import from clipboard", "win.import_clipboard");
            add_menu.append ("Import WireGuard / AmneziaWG config…", "win.import_wg_file");
            add_menu.append ("New Group / Subscription", "win.new_sub_group");
            add_menu.append_submenu ("Add new node", node_menu);

            var add_btn = new Gtk.MenuButton ();
            add_btn.icon_name = "plus-symbolic";
            add_btn.tooltip_text = "Add";
            add_btn.add_css_class ("flat");
            add_btn.valign = Gtk.Align.CENTER;
            add_btn.menu_model = add_menu;

            var tab_bar = new Adw.TabBar ();
            tab_bar.view = server_tabs;
            tab_bar.autohide = false;
            tab_bar.hexpand = true;
            tab_bar.valign = Gtk.Align.CENTER;
            tab_bar.add_css_class ("flat-tabbar");

            bench_ping_btn = Widgets.icon_button ("vertical-arrows-symbolic", "Real delay test");
            bench_ping_btn.clicked.connect (() => { run_benchmark (false); });
            bench_speed_btn = Widgets.icon_button ("speedometer-symbolic", "Real delay & speed test");
            bench_speed_btn.clicked.connect (() => { run_benchmark (true); });

            servers_topbar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            servers_topbar.margin_start = 6;
            servers_topbar.margin_end = 6;
            servers_topbar.valign = Gtk.Align.CENTER;
            servers_topbar.append (add_btn);
            servers_topbar.append (tab_bar);
            servers_topbar.append (bench_ping_btn);
            servers_topbar.append (bench_speed_btn);
            return servers_topbar;
        }

        private SubGroup? tab_menu_group = null;

        private void build_server_tabs () {
            server_tabs = new Adw.TabView ();
            server_tabs.vexpand = true;
            setup_tab_swipe ();

            server_tabs.notify["selected-page"].connect (() => {
                if (updating_ui || server_tabs.selected_page == null) return;
                settings.last_active_tab = server_tabs.selected_page.title;
                settings.save ();
            });

            // tabs aren't user-closeable: need allow_tab_close flag so rebuild can close pages without AdwTabView freaking out
            server_tabs.close_page.connect ((view, page) => {
                view.close_page_finish (page, allow_tab_close);
                return true;
            });

            server_tabs.page_reordered.connect (on_tab_reordered);
            setup_tab_menu ();
        }

        private void setup_tab_menu () {
            var update = group_tab_action ("tab_update", (g) => { update_one_group.begin (g); });
            var edit = group_tab_action ("tab_edit", (g) => { show_group_dialog (g); });
            var copy = group_tab_action ("tab_copy", (g) => { group_copy_urls (g); });
            var qr = group_tab_action ("tab_qr", (g) => { group_show_qr (g); });
            var delete = group_tab_action ("tab_delete", (g) => { remove_group (g); });

            var menu = new GLib.Menu ();
            menu.append ("Update subscription", "win.tab_update");
            menu.append ("Edit", "win.tab_edit");
            menu.append ("Copy to clipboard", "win.tab_copy");
            menu.append ("QR Code", "win.tab_qr");
            menu.append ("Delete", "win.tab_delete");
            server_tabs.menu_model = menu;

            // "All" tab has no SubGroup object, disable group-specific context actions
            server_tabs.setup_menu.connect ((page) => {
                if (page == null) return;
                tab_menu_group = page.child.get_data<SubGroup> ("group");
                foreach (var action in new GLib.SimpleAction[] { update, edit, copy, qr, delete }) {
                    action.set_enabled (tab_menu_group != null);
                }
            });
        }

        private delegate void GroupAction (SubGroup group);

        private GLib.SimpleAction group_tab_action (string name, owned GroupAction run) {
            var action = new GLib.SimpleAction (name, null);
            action.activate.connect (() => {
                if (tab_menu_group != null) run (tab_menu_group);
            });
            add_action (action);
            return action;
        }

        // "All" tab must stay first: rebuild tabs if user dragged it
        private void on_tab_reordered (Adw.TabPage page, int position) {
            if (updating_ui) return;
            var group = page.child.get_data<SubGroup> ("group");
            if (group == null) {
                GLib.Idle.add (() => {
                    rebuild_server_tabs ();
                    return GLib.Source.REMOVE;
                });
                return;
            }
            int index = 0;
            for (int p = 0; p < server_tabs.n_pages; p++) {
                var other = server_tabs.get_nth_page (p);
                if (other == page) break;
                if (other.child.get_data<SubGroup> ("group") != null) index++;
            }
            store.move_group (group, index);
            rebuild_subs_ui ();
        }

        private void rebuild_server_tabs () {
            updating_ui = true;
            allow_tab_close = true;
            while (server_tabs.n_pages > 0) {
                server_tabs.close_page (server_tabs.get_nth_page (0));
            }
            allow_tab_close = false;
            server_views = new GLib.GenericArray<Gtk.ListView> ();

            // "All" tab is optional, but forced if no groups exist yet
            Adw.TabPage? first = null;
            Adw.TabPage? remembered = null;
            if (settings.show_all_tab || store.groups.get_n_items () == 0) {
                var all = server_tabs.append (make_server_tab (null));
                all.title = "All";
                first = all;
                if (settings.last_active_tab == "All") remembered = all;
            }

            for (uint i = 0; i < store.groups.get_n_items (); i++) {
                var g = (SubGroup) store.groups.get_item (i);
                var page = server_tabs.append (make_server_tab (g));
                page.title = g.name;
                if (first == null) first = page;
                if (remembered == null && settings.last_active_tab == g.name) remembered = page;
            }
            var selected_page = remembered ?? first;
            server_tabs.selected_page = selected_page;
            restore_active_selection ();
            updating_ui = false;
        }

        private Gtk.Widget make_server_tab (SubGroup? group) {
            Gtk.CustomFilter filter;
            if (group == null) {
                filter = new Gtk.CustomFilter ((obj) => { return true; });
            } else {
                var g = group;
                filter = new Gtk.CustomFilter ((obj) => {
                    var n = (Models.Node) obj;
                    // manual nodes don't have sub_url, match them by group name
                    if (n.sub_url == "") return n.group_name == g.name;
                    for (uint i = 0; i < g.urls.get_n_items (); i++) {
                        if (n.sub_url == g.urls.get_string (i)) return true;
                    }
                    return false;
                });
            }
            var filter_model = new Gtk.FilterListModel (store.nodes, filter);
            var sort_model = new Gtk.SortListModel (filter_model, current_sorter);
            var sel = new Gtk.SingleSelection (sort_model);
            sel.autoselect = false;

            // guard updating_ui so initializing selection doesn't trigger row activation
            bool prev_updating_ui = updating_ui;
            updating_ui = true;
            for (uint i = 0; i < sort_model.get_n_items (); i++) {
                var n = sort_model.get_item (i) as Models.Node;
                if (active_node != null && n == active_node) {
                    sel.selected = i;
                    break;
                }
            }
            updating_ui = prev_updating_ui;

            var factory = new Gtk.SignalListItemFactory ();
            factory.setup.connect ((f, obj) => {
                var row = new NodeRow ();
                ((Gtk.ListItem) obj).child = row;
                row.context_menu_requested.connect ((n, x, y) => {
                    show_node_context_menu (n, row, x, y);
                });
            });
            factory.bind.connect ((f, obj) => {
                var item = (Gtk.ListItem) obj;
                var row = (NodeRow) item.child;
                row.show_group = (group == null);
                row.bind ((Models.Node) item.item);
            });
            factory.unbind.connect ((f, obj) => {
                ((NodeRow) ((Gtk.ListItem) obj).child).unbind ();
            });

            sel.notify["selected-item"].connect (() => {
                if (updating_ui || store.syncing) return;
                if (runner.running) return;
                var n = sel.selected_item as Models.Node;
                if (n != null) {
                    set_active (n);
                }
            });

            var view = new Gtk.ListView (sel, factory);
            view.add_css_class ("servers-list");
            view.activate.connect ((pos) => {
                var n = sel.get_item (pos) as Models.Node;
                if (n == null) return;
                sel.selected = pos;
                on_row_activated (n);
            });
            server_views.add (view);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER; // horizontal scroll switches tabs instead
            scroll.child = view;
            scroll.vexpand = true;
            scroll.set_data<Gtk.SingleSelection> ("selection", sel);
            scroll.set_data<Gtk.SortListModel> ("sort_model", sort_model);
            if (group != null) scroll.set_data<SubGroup> ("group", group);
            return scroll;
        }

        // tab switching gesture engine:
        // touchscreen horizontal swipe, touchpad two-finger scroll, or tilt wheel.
        // controllers use CAPTURE phase to intercept before the ScrolledWindow swallows events.

        private const double SWIPE_TOUCH_DISTANCE = 80.0;     // px, touchscreen
        private const double SWIPE_SCROLL_DISTANCE = 120.0;   // px, touchpad
        private double swipe_scroll_dx = 0.0;
        private bool swipe_scroll_locked = false;
        private unowned Gdk.EventSequence? swipe_touch_seq = null;
        private bool swipe_touch_multi = false;
        private double swipe_touch_x = 0.0;
        private double swipe_touch_y = 0.0;
        private uint32 swipe_touch_time = 0;

        private void switch_tab_by (int dir) {
            if (server_tabs.n_pages < 2) return;
            bool moved = dir > 0 ? server_tabs.select_next_page () : server_tabs.select_previous_page ();
            if (!moved) return;
            foreach (var v in server_views) {
                if (v.get_ancestor (typeof (Gtk.ScrolledWindow)) == server_tabs.selected_page.child) {
                    v.grab_focus ();
                    break;
                }
            }
        }

        private void setup_tab_swipe () {
            // GTK4 touch gesture nightmare: child list rows claim touch sequences on press,
            // immediately cancelling any parent GtkGestureSwipe before finger travel starts.
            // Using EventControllerLegacy in CAPTURE phase to sniff raw touch events without stealing
            // propagation so kinetic scrolling still works.
            var touch = new Gtk.EventControllerLegacy ();
            touch.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            touch.event.connect ((ev) => {
                var type = ev.get_event_type ();
                if (type == Gdk.EventType.TOUCH_BEGIN) {
                    // drop stale touches if finger lifted over a popover or outside window
                    if (swipe_touch_seq != null && ev.get_time () - swipe_touch_time > 1000) {
                        swipe_touch_seq = null;
                    }
                    if (swipe_touch_seq != null) {
                        swipe_touch_multi = true; // pinch/multitouch, ignore
                    } else {
                        swipe_touch_seq = ev.get_event_sequence ();
                        swipe_touch_multi = false;
                        swipe_touch_time = ev.get_time ();
                        ev.get_position (out swipe_touch_x, out swipe_touch_y);
                    }
                } else if (type == Gdk.EventType.TOUCH_END && ev.get_event_sequence () == swipe_touch_seq) {
                    double x, y;
                    ev.get_position (out x, out y);
                    double ox = x - swipe_touch_x, oy = y - swipe_touch_y;
                    bool multi = swipe_touch_multi;
                    swipe_touch_seq = null;
                    if (!multi && Math.fabs (ox) >= SWIPE_TOUCH_DISTANCE && Math.fabs (ox) >= 2.0 * Math.fabs (oy)) {
                        switch_tab_by (ox < 0 ? 1 : -1);
                    }
                } else if (type == Gdk.EventType.TOUCH_CANCEL && ev.get_event_sequence () == swipe_touch_seq) {
                    swipe_touch_seq = null;
                }
                return false;
            });
            server_tabs.add_controller (touch);

            var scroll = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.BOTH_AXES);
            scroll.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            scroll.scroll_begin.connect (() => {
                swipe_scroll_dx = 0.0;
                swipe_scroll_locked = false;
            });
            scroll.scroll_end.connect (() => {
                swipe_scroll_dx = 0.0;
                swipe_scroll_locked = false;
            });
            scroll.scroll.connect ((dx, dy) => {
                if (Math.fabs (dx) <= Math.fabs (dy)) return false; // mostly vertical, let list scroll
                if (scroll.get_unit () == Gdk.ScrollUnit.WHEEL) {
                    switch_tab_by (dx > 0 ? 1 : -1);
                    return true;
                }
                if (swipe_scroll_locked) return true;
                swipe_scroll_dx += dx;
                if (Math.fabs (swipe_scroll_dx) >= SWIPE_SCROLL_DISTANCE) {
                    switch_tab_by (swipe_scroll_dx > 0 ? 1 : -1);
                    swipe_scroll_locked = true;
                }
                return true;
            });
            server_tabs.add_controller (scroll);
        }

        private Models.Node? current_selected_node () {
            var page = server_tabs.selected_page;
            if (page == null) return null;
            var sel = page.child.get_data<Gtk.SingleSelection> ("selection");
            if (sel == null) return null;
            return sel.selected_item as Models.Node;
        }

        public void restore_active_selection () {
            if (active_node == null || server_tabs == null) return;
            for (int p = 0; p < server_tabs.n_pages; p++) {
                var page = server_tabs.get_nth_page (p);
                if (page == null) continue;
                var sel = page.child.get_data<Gtk.SingleSelection> ("selection");
                if (sel == null) continue;
                for (uint i = 0; i < sel.model.get_n_items (); i++) {
                    var n = (Models.Node) sel.model.get_item (i);
                    if (n == active_node) {
                        sel.selected = i;
                        break;
                    }
                }
            }
        }

        public void locate_active_node () {
            if (active_node == null) return;

            if (nav_list != null) {
                nav_list.select_row (nav_list.get_row_at_index (0));
            }
            content_stack.visible_child_name = "servers";
            content_title.title = "Servers";
            if (split_view.collapsed) {
                split_view.show_sidebar = false;
            }

            Adw.TabPage? target_page = null;

            var cur_page = server_tabs.selected_page;
            if (cur_page != null && cur_page.child != null) {
                var scroll = cur_page.child as Gtk.ScrolledWindow;
                if (scroll != null) {
                    var sel = scroll.get_data<Gtk.SingleSelection> ("selection");
                    if (sel != null) {
                        for (uint i = 0; i < sel.model.get_n_items (); i++) {
                            var n = (Models.Node) sel.model.get_item (i);
                            if (n == active_node) {
                                target_page = cur_page;
                                break;
                            }
                        }
                    }
                }
            }

            if (target_page == null) {
                for (int p = 0; p < server_tabs.n_pages; p++) {
                    var page = server_tabs.get_nth_page (p);
                    if (page == null || page.child == null) continue;
                    var scroll = page.child as Gtk.ScrolledWindow;
                    if (scroll == null) continue;
                    var sel = scroll.get_data<Gtk.SingleSelection> ("selection");
                    if (sel == null) continue;
                    for (uint i = 0; i < sel.model.get_n_items (); i++) {
                        var n = (Models.Node) sel.model.get_item (i);
                        if (n == active_node) {
                            target_page = page;
                            break;
                        }
                    }
                    if (target_page != null) break;
                }
            }

            if (target_page != null) {
                server_tabs.selected_page = target_page;
                var scroll = target_page.child as Gtk.ScrolledWindow;
                if (scroll != null) {
                    var sel = scroll.get_data<Gtk.SingleSelection> ("selection");
                    var view = scroll.child as Gtk.ListView;
                    if (sel != null && view != null) {
                        for (uint i = 0; i < sel.model.get_n_items (); i++) {
                            var n = (Models.Node) sel.model.get_item (i);
                            if (n == active_node) {
                                sel.selected = i;
                                view.scroll_to (i, Gtk.ListScrollFlags.SELECT, null);
                                break;
                            }
                        }
                    }
                }
            }
        }

    }
}
