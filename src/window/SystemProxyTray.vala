using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private Gtk.PopoverMenu? tray_popover = null;

        private void on_sysproxy_changed () {
            if (updating_ui) return;
            set_sysproxy_state ((int) sysproxy_dropdown.selected);
        }

        public int get_sysproxy_state () {
            return (int) sysproxy_dropdown.selected;
        }

        public void set_sysproxy_state (int state) {
            updating_ui = true;
            sysproxy_dropdown.selected = state;
            updating_ui = false;
            if (settings.sysproxy_mode != state) {
                settings.sysproxy_mode = state;
                settings.save ();
            }
            if (state == 1) {
                SystemProxy.apply (settings);
                append_log ("[app] system proxy -> manual (127.0.0.1).");
                show_toast ("System proxy enabled.");
            } else if (state == 0) {
                SystemProxy.clear ();
                append_log ("[app] system proxy -> none.");
                show_toast ("System proxy cleared.");
            } else {
                append_log ("[app] system proxy -> do not change.");
                show_toast ("Do not change system proxy mode active.");
            }
            if (tray_icon != null) {
                tray_icon.update_menu ();
            }
        }

        public void toggle_visibility () {
            if (visible) {
                visible = false;
            } else {
                present ();
            }
        }

        public void copy_proxy_command () {
            string cmd = "export http_proxy=http://127.0.0.1:%d; export https_proxy=http://127.0.0.1:%d; export all_proxy=socks5://127.0.0.1:%d;".printf (
                settings.current_mixed_port, settings.current_mixed_port, settings.current_mixed_port);
            Clipboard.copy (cmd);
            show_toast ("Proxy command copied to clipboard.");
        }

        public void show_tray_context_menu (int x, int y) {
            if (tray_popover == null) {
                var menu_model = new GLib.Menu ();

                var sec1 = new GLib.Menu ();
                // prefix with "tray." - if we registered as "win", GTK would nuke the window's own actions
                sec1.append ("Display GUI", "tray.present_gui");
                sec1.append ("Show or hide the main window", "tray.toggle_gui");
                sec1.append ("Copy proxy command to clipboard", "tray.copy_cmd");
                menu_model.append_section (null, sec1);

                var sec2 = new GLib.Menu ();
                sec2.append ("Clear proxy", "tray.sysproxy_clear");
                sec2.append ("Set proxy", "tray.sysproxy_set");
                sec2.append ("Off proxy", "tray.sysproxy_keep");
                menu_model.append_section (null, sec2);

                var sec3 = new GLib.Menu ();
                sec3.append ("Import Share Links from clipboard", "tray.import_clipboard");
                sec3.append ("Update subscriptions without proxy", "tray.update_subs_direct");
                menu_model.append_section (null, sec3);

                var action_group = new GLib.SimpleActionGroup ();

                var act_present = new GLib.SimpleAction ("present_gui", null);
                act_present.activate.connect (() => { present (); });
                action_group.add_action (act_present);

                var act_toggle = new GLib.SimpleAction ("toggle_gui", null);
                act_toggle.activate.connect (() => { toggle_visibility (); });
                action_group.add_action (act_toggle);

                var act_copy = new GLib.SimpleAction ("copy_cmd", null);
                act_copy.activate.connect (() => { copy_proxy_command (); });
                action_group.add_action (act_copy);

                var act_clear = new GLib.SimpleAction ("sysproxy_clear", null);
                act_clear.activate.connect (() => { set_sysproxy_state (0); });
                action_group.add_action (act_clear);

                var act_set = new GLib.SimpleAction ("sysproxy_set", null);
                act_set.activate.connect (() => { set_sysproxy_state (1); });
                action_group.add_action (act_set);

                var act_keep = new GLib.SimpleAction ("sysproxy_keep", null);
                act_keep.activate.connect (() => { set_sysproxy_state (2); });
                action_group.add_action (act_keep);

                var act_import = new GLib.SimpleAction ("import_clipboard", null);
                act_import.activate.connect (() => { handle_paste (); });
                action_group.add_action (act_import);

                var act_direct = new GLib.SimpleAction ("update_subs_direct", null);
                act_direct.activate.connect (() => { update_subs_direct.begin (); });
                action_group.add_action (act_direct);

                insert_action_group ("tray", action_group);

                tray_popover = new Gtk.PopoverMenu.from_model (menu_model);
                tray_popover.set_parent (this);
                tray_popover.has_arrow = false;
            }

            present ();
            tray_popover.popup ();
        }
    }
}
