using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private Gtk.Box subs_groups_box;
        private Gtk.Box subs_actions_box;
        private Gtk.Button update_subs_button;

        private Gtk.Widget build_subs_page () {
            subs_groups_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 24);
            subs_groups_box.margin_top = 12;
            subs_groups_box.margin_bottom = 12;
            subs_groups_box.margin_start = 12;
            subs_groups_box.margin_end = 12;

            var clamp = new Adw.Clamp ();
            clamp.maximum_size = 720;
            clamp.child = subs_groups_box;

            var scroll = new Gtk.ScrolledWindow ();
            scroll.child = clamp;
            scroll.vexpand = true;

            update_subs_button = Widgets.icon_label_button ("arrow-clockwise-symbolic", "Update All");
            update_subs_button.remove_css_class ("flat");
            update_subs_button.clicked.connect (() => { update_subs.begin (); });

            var new_btn = Widgets.icon_label_button ("plus-symbolic", "New Group");
            new_btn.remove_css_class ("flat");
            new_btn.clicked.connect (() => { show_group_dialog (null); });

            subs_actions_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            subs_actions_box.valign = Gtk.Align.CENTER;
            subs_actions_box.append (update_subs_button);
            subs_actions_box.append (new_btn);

            rebuild_subs_ui ();
            return scroll;
        }

        private void rebuild_subs_ui () {
            if (subs_actions_box.get_parent () != null) subs_actions_box.unparent ();
            Gtk.Widget? child;
            while ((child = subs_groups_box.get_first_child ()) != null) subs_groups_box.remove (child);

            var list = new Adw.PreferencesGroup ();
            list.header_suffix = subs_actions_box;
            for (uint i = 0; i < store.groups.get_n_items (); i++) {
                list.add (build_group_row ((SubGroup) store.groups.get_item (i)));
            }
            subs_groups_box.append (list);
        }

        private static string group_summary (SubGroup g) {
            uint n = g.urls.get_n_items ();
            // do NOT nest ?: mixing string literals and printf here!
            // valac 0.56.18 emits use-after-free C code that corrupts the string.
            string text;
            if (n == 0) text = "No URLs";
            else if (n == 1) text = "1 URL";
            else text = "%u URLs".printf (n);
            if (g.enable_update && g.update_interval > 0) text += " · every %d min".printf (g.update_interval);
            return text;
        }

        private Adw.ActionRow build_group_row (SubGroup g) {
            var row = new Adw.ActionRow ();
            row.title = g.name;
            row.subtitle = group_summary (g);
            row.activatable = true;
            row.activated.connect (() => { show_group_dialog (g); });

            var handle = new Gtk.Image.from_icon_name ("list-drag-handle-symbolic");
            handle.add_css_class ("dim-label");
            handle.valign = Gtk.Align.CENTER;
            handle.margin_end = 8;
            row.add_prefix (handle);
            make_group_row_draggable (row, g);

            var update_btn = Widgets.icon_button ("arrow-clockwise-symbolic", "Update this group");
            update_btn.clicked.connect (() => { update_one_group.begin (g); });
            var edit_btn = Widgets.icon_button ("sliders-symbolic", "Edit group");
            edit_btn.clicked.connect (() => { show_group_dialog (g); });
            var delete_btn = Widgets.icon_button ("user-trash-symbolic", "Delete group");
            delete_btn.clicked.connect (() => { remove_group (g); });
            row.add_suffix (update_btn);
            row.add_suffix (edit_btn);
            row.add_suffix (delete_btn);

            var right_click = new Gtk.GestureClick ();
            right_click.button = 3;
            right_click.pressed.connect ((n_press, x, y) => { show_group_context_menu (g, row, x, y); });
            row.add_controller (right_click);
            return row;
        }

        // DnD reordering for sub group rows
        private void make_group_row_draggable (Adw.ActionRow row, SubGroup g) {
            var source = new Gtk.DragSource ();
            source.set_actions (Gdk.DragAction.MOVE);
            source.prepare.connect ((x, y) => {
                var value = GLib.Value (typeof (SubGroup));
                value.set_object (g);
                return new Gdk.ContentProvider.for_value (value);
            });
            source.drag_begin.connect ((drag) => {
                var title = new Gtk.Label (g.name);
                title.halign = Gtk.Align.START;
                title.add_css_class ("heading");
                var subtitle = new Gtk.Label (group_summary (g));
                subtitle.halign = Gtk.Align.START;
                subtitle.add_css_class ("dim-label");
                var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
                card.add_css_class ("drag-icon-card");
                card.append (title);
                card.append (subtitle);
                ((Gtk.DragIcon) Widgets.drag_icon_for (drag)).child = card;
            });
            row.add_controller (source);

            var target = new Gtk.DropTarget (typeof (SubGroup), Gdk.DragAction.MOVE);
            target.drop.connect ((value, x, y) => {
                var dragged = value.get_object () as SubGroup;
                if (dragged == null || dragged == g) return false;
                uint position;
                if (!store.groups.find (g, out position)) return false;
                store.move_group (dragged, (int) position);
                rebuild_subs_ui ();
                rebuild_server_tabs ();
                return true;
            });
            row.add_controller (target);
        }

        private void show_group_context_menu (SubGroup g, Gtk.Widget anchor, double x, double y) {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.add_css_class ("node-menu");
            var popover = popover_at (anchor, x, y, box);

            add_menu_item (box, popover, "Edit", () => { show_group_dialog (g); });
            add_menu_item (box, popover, "Copy to clipboard", () => { group_copy_urls (g); });
            add_menu_item (box, popover, "QR Code", () => { group_show_qr (g); });
            box.append (make_sep ());
            add_menu_item (box, popover, "Delete", () => { remove_group (g); }).add_css_class ("destructive-action");

            anchor.add_css_class ("menu-open");
            popover.closed.connect (() => {
                anchor.remove_css_class ("menu-open");
                popover.unparent ();
            });
            popover.popup ();
        }

        private void group_copy_urls (SubGroup g) {
            if (g.urls.get_n_items () == 0) return;
            var sb = new GLib.StringBuilder ();
            for (uint i = 0; i < g.urls.get_n_items (); i++) {
                sb.append (g.urls.get_string (i));
                if (i < g.urls.get_n_items () - 1) sb.append ("\n");
            }
            Clipboard.copy (sb.str);
            show_toast ("Copied %u URL(s) to clipboard.".printf (g.urls.get_n_items ()));
        }

        private void group_show_qr (SubGroup g) {
            if (g.urls.get_n_items () == 0) {
                show_toast ("No URLs in this group.");
                return;
            }
            string[] links = {};
            for (uint i = 0; i < g.urls.get_n_items (); i++) links += g.urls.get_string (i);
            show_qr_dialog ("QR Code", g.name, links);
        }

        // core subscription fetch worker for group/all/direct/auto-updates
        private async void fetch_groups (SubGroup[] groups, bool direct, string tag,
                                         out int total, out int failed, out int urls) {
            total = 0; failed = 0; urls = 0;
            int64 now = GLib.get_real_time () / 1000000;
            foreach (var g in groups) {
                for (uint j = 0; j < g.urls.get_n_items (); j++) {
                    string url = g.urls.get_string (j);
                    if (!url.has_prefix ("http://") && !url.has_prefix ("https://")) continue;
                    urls++;
                    string safe_url = Util.mask_url (url);
                    append_log ("[%s] updating '%s'%s: %s".printf (tag, g.name, direct ? " (no proxy)" : "", safe_url));
                    try {
                        int c = yield sub_mgr.update_one (url, store, g, settings, direct);
                        total += c;
                        append_log ("[%s] %s -> %d nodes".printf (tag, safe_url, c));
                    } catch (GLib.Error e) {
                        failed++;
                        append_log ("[%s] subscription failed (%s): %s".printf (tag, safe_url, e.message));
                    }
                }
                g.last_update_time = now;
            }
        }

        private void finish_groups_update () {
            store.save_subs ();
            store.save_nodes ();
            restore_active_node_state ();
            rebuild_subs_ui ();
            rebuild_server_tabs ();
        }

        private async void update_one_group (SubGroup g) {
            int total, failed, urls;
            yield fetch_groups ({ g }, false, "app", out total, out failed, out urls);
            if (urls == 0) {
                show_toast ("Group '%s' is a local group (no external URLs).".printf (g.name));
                return;
            }
            finish_groups_update ();
            show_toast ("Updated group '%s': %d nodes, %d failed.".printf (g.name, total, failed));
        }

        private void show_group_dialog (SubGroup? group) {
            var dialog = new GroupEditDialog (store, group);
            dialog.saved.connect (() => {
                rebuild_subs_ui ();
                rebuild_server_tabs ();
            });
            dialog.present (this);
        }

        private void remove_group (SubGroup g) {
            Widgets.confirm_delete (this, "Delete Group",
                "Are you sure you want to delete '%s' and all its nodes?".printf (g.name), () => {
                    do_remove_group (g);
                });
        }

        private void do_remove_group (SubGroup g) {
            for (uint j = 0; j < g.urls.get_n_items (); j++) {
                store.remove_nodes_of_sub (g.urls.get_string (j));
            }
            store.remove_manual_nodes (g.name);
            uint position;
            if (store.groups.find (g, out position)) store.groups.remove (position);
            store.save_subs ();
            store.save_nodes ();
            rebuild_subs_ui ();
            rebuild_server_tabs ();
        }

        private SubGroup[] all_groups () {
            SubGroup[] gs = {};
            for (uint i = 0; i < store.groups.get_n_items (); i++) gs += (SubGroup) store.groups.get_item (i);
            return gs;
        }

        private async void update_subs () {
            update_subs_button.sensitive = false;
            int total, failed, urls;
            yield fetch_groups (all_groups (), false, "app", out total, out failed, out urls);
            update_subs_button.sensitive = true;
            finish_groups_update ();
            if (urls == 0) show_toast ("No subscriptions configured.");
            else show_toast ("Updated: %d nodes, %d failed.".printf (total, failed));
        }

        public async void update_subs_direct () {
            // TUN hijacks all routing, so direct update is physically impossible while TUN is hot
            if (runner.running && runner.tun_mode) {
                show_toast ("Not available while TUN is on: all traffic goes through the tunnel.");
                append_log ("[app] direct subscription update skipped: TUN is active.");
                return;
            }
            if (update_subs_button != null) update_subs_button.sensitive = false;
            int total, failed, urls;
            yield fetch_groups (all_groups (), true, "app", out total, out failed, out urls);
            if (update_subs_button != null) update_subs_button.sensitive = true;
            finish_groups_update ();
            if (urls == 0) show_toast ("No subscriptions configured.");
            else show_toast ("Updated directly: %d nodes, %d failed.".printf (total, failed));
        }

        private async void auto_update_groups () {
            int64 now = GLib.get_real_time () / 1000000;
            SubGroup[] due = {};
            foreach (var g in all_groups ()) {
                if (!g.enable_update || g.urls.get_n_items () == 0) continue;
                int64 interval_sec = (int64) (g.update_interval < 5 ? 5 : g.update_interval) * 60;
                if (g.last_update_time == 0 || (now - g.last_update_time) >= interval_sec) due += g;
            }
            if (due.length == 0) return;
            int total, failed, urls;
            yield fetch_groups (due, false, "auto-update", out total, out failed, out urls);
            finish_groups_update ();
            show_toast ("Automatic subscription update: %d nodes, %d failed.".printf (total, failed));
        }
    }
}
