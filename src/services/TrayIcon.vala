using Vector.Models;
using Vector.Engines;
namespace Vector.Services {

    // dbusmenu is finicky as hell: items are 1-indexed, 0 is reserved for root
    [DBus (name = "com.canonical.dbusmenu")]
    public class DBusMenu : Object {
        private MainWindow win;

        private const string SEPARATOR = "";
        private const string[] MENU_ITEMS = {
            "Display GUI",                          // 1
            "Show or hide the main window",         // 2
            "Copy proxy command to clipboard",      // 3
            SEPARATOR,                              // 4
            "Clear proxy",                          // 5  desktop proxy mode 0
            "Set proxy",                            // 6  desktop proxy mode 1
            "Off proxy",                            // 7  desktop proxy mode 2
            SEPARATOR,                              // 8
            "Import Share Links from clipboard",    // 9
            "Update subscriptions without proxy",   // 10
            SEPARATOR,                              // 11
            "Full Exit"                             // 12
        };
        // items 5-7 map to desktop proxy mode (id - 5)
        private const int FIRST_PROXY_MODE_ITEM = 5;
        private const int LAST_PROXY_MODE_ITEM = 7;

        private string[] empty_paths = new string[0];

        public uint Version { get { return 3; } }
        public string TextDirection { get { return "ltr"; } }
        public string Status { get { return "normal"; } }
        public string[] IconThemePath { get { return empty_paths; } }

        public signal void LayoutUpdated (uint revision, int parentId);
        public signal void ItemsPropertiesUpdated (GLib.Variant updatedProps, GLib.Variant removedProps);
        public signal void ItemActivationRequested (int id, uint timestamp);

        // dbusmenu protocol quirk: GetLayout must report the exact revision last announced or tray ignores update
        private uint layout_revision = 1;

        public DBusMenu (MainWindow win) {
            this.win = win;
        }

        // poke the tray to re-fetch menu layout after proxy mode changed
        [DBus (visible = false)]
        public void announce_layout () {
            layout_revision++;
            LayoutUpdated (layout_revision, 0);
        }

        private static GLib.Variant item_props (int id, int proxy_mode) {
            var props = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
            if (id >= 1 && id <= MENU_ITEMS.length) {
                string label = MENU_ITEMS[id - 1];
                if (label != SEPARATOR) props.add ("{sv}", "label", new GLib.Variant.string (label));
                props.add ("{sv}", "type", new GLib.Variant.string (label == SEPARATOR ? "separator" : "standard"));
                if (id >= FIRST_PROXY_MODE_ITEM && id <= LAST_PROXY_MODE_ITEM) {
                    props.add ("{sv}", "toggle-type", new GLib.Variant.string ("radio"));
                    props.add ("{sv}", "toggle-state", new GLib.Variant.int32 (id - FIRST_PROXY_MODE_ITEM == proxy_mode ? 1 : 0));
                }
                props.add ("{sv}", "enabled", new GLib.Variant.boolean (true));
            }
            return props.end ();
        }

        private static GLib.Variant layout_node (int id, GLib.Variant props, GLib.Variant[] children) {
            var children_builder = new GLib.VariantBuilder (new GLib.VariantType ("av"));
            foreach (var child in children) children_builder.add ("v", child);
            var node = new GLib.VariantBuilder (new GLib.VariantType ("(ia{sv}av)"));
            node.add ("i", id);
            node.add_value (props);
            node.add_value (children_builder.end ());
            return node.end ();
        }

        private static GLib.Variant root_layout (int proxy_mode) {
            GLib.Variant[] items = {};
            for (int id = 1; id <= MENU_ITEMS.length; id++) items += layout_node (id, item_props (id, proxy_mode), {});
            var props = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
            props.add ("{sv}", "children-display", new GLib.Variant.string ("submenu"));
            return layout_node (0, props.end (), items);
        }

        private void activate_item (int id) {
            if (id >= FIRST_PROXY_MODE_ITEM && id <= LAST_PROXY_MODE_ITEM) {
                win.set_sysproxy_state (id - FIRST_PROXY_MODE_ITEM);
                announce_layout ();
                return;
            }
            switch (id) {
                case 1:  win.present (); break;
                case 2:  win.toggle_visibility (); break;
                case 3:  win.copy_proxy_command (); break;
                case 9:  win.handle_paste (); break;
                case 10: win.update_subs_direct.begin (); break;
                case 12: win.full_exit (); break;
                default: break;
            }
        }

        public void GetLayout (int parentId, int recursionDepth, string[] propertyNames, out uint revision, [DBus (signature = "(ia{sv}av)")] out GLib.Variant layout) throws GLib.Error {
            revision = layout_revision;
            layout = root_layout (win.get_sysproxy_state ());
        }

        public void GetGroupProperties (int[] ids, string[] propertyNames, [DBus (signature = "a(ia{sv})")] out GLib.Variant properties) throws GLib.Error {
            var builder = new GLib.VariantBuilder (new GLib.VariantType ("a(ia{sv})"));
            int proxy_mode = win.get_sysproxy_state ();
            foreach (int id in ids) {
                var tuple = new GLib.VariantBuilder (new GLib.VariantType ("(ia{sv})"));
                tuple.add ("i", id);
                tuple.add_value (item_props (id, proxy_mode));
                builder.add_value (tuple.end ());
            }
            properties = builder.end ();
        }

        public void GetProperty (int id, string name, out GLib.Variant value) throws GLib.Error {
            value = new GLib.Variant.string ("");
        }

        public void Event (int id, string eventId, GLib.Variant data, uint timestamp) throws GLib.Error {
            if (eventId != "clicked") return;
            GLib.Idle.add (() => {
                activate_item (id);
                return GLib.Source.REMOVE;
            });
        }

        public void EventGroup (GLib.Variant events, out int[] idErrors) throws GLib.Error {
            idErrors = new int[0];
        }

        public void AboutToShow (int id, out bool needUpdate) throws GLib.Error {
            needUpdate = false;
        }

        public void AboutToShowGroup (int[] ids, out int[] updatesNeeded, out int[] idErrors) throws GLib.Error {
            updatesNeeded = new int[0];
            idErrors = new int[0];
        }
    }

    // StatusNotifierItem (KDE/freedesktop standard tray)
    [DBus (name = "org.kde.StatusNotifierItem")]
    public class StatusNotifierItem : Object {
        private MainWindow win;
        private CoreRunner runner;

        private string icon_theme_path;
        private GLib.ObjectPath menu_path;

        public string Category { get { return "ApplicationStatus"; } }
        public string Id { get { return "vector"; } }
        public string Title { get { return "Vector Proxy"; } }
        public string Status { get { return runner.running ? "Active" : "Passive"; } }
        public int WindowId { get { return 0; } }
        public string IconName { get { return runner.running ? "network-vpn-symbolic" : "io.github.dp0sk.Vector"; } }
        public string OverlayIconName { get { return ""; } }
        public string AttentionIconName { get { return ""; } }
        public string AttentionMovieName { get { return ""; } }
        public string IconThemePath { get { return icon_theme_path; } }
        public GLib.ObjectPath Menu { owned get { return menu_path; } }
        public bool ItemIsMenu { get { return false; } }

        public StatusNotifierItem (MainWindow win, CoreRunner runner) {
            this.win = win;
            this.runner = runner;
            this.icon_theme_path = GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "icons");
            this.menu_path = new GLib.ObjectPath ("/StatusNotifierMenu");

            this.runner.state_changed.connect ((running) => {
                this.NewStatus (running ? "Active" : "Passive");
                this.NewIcon ();
            });
        }

        public void Activate (int x, int y) throws GLib.Error {
            GLib.Idle.add (() => {
                win.toggle_visibility ();
                return false;
            });
        }

        public void SecondaryActivate (int x, int y) throws GLib.Error {
            Activate (x, y);
        }

        public void ContextMenu (int x, int y) throws GLib.Error {
            GLib.Idle.add (() => {
                win.show_tray_context_menu (x, y);
                return false;
            });
        }

        public void Scroll (int delta, string orientation) throws GLib.Error {
        }

        public signal void NewTitle ();
        public signal void NewIcon ();
        public signal void NewAttentionIcon ();
        public signal void NewStatus (string status);
        public signal void NewToolTip ();
    }

    [DBus (name = "org.kde.StatusNotifierWatcher")]
    interface StatusNotifierWatcher : Object {
        public abstract void register_status_notifier_item (string service) throws Error;
    }

    // export SNI + DBusMenu and hook StatusNotifierWatcher (re-register if plasma panel crashes & restarts)
    public class TrayIcon : Object {
        private StatusNotifierItem? item = null;
        private DBusMenu? menu = null;
        private GLib.DBusConnection? dbus_conn = null;

        public TrayIcon (MainWindow win, CoreRunner runner) {
            item = new StatusNotifierItem (win, runner);
            menu = new DBusMenu (win);
            register_dbus ();
        }

        public void update_menu () {
            if (menu != null) {
                menu.announce_layout ();
            }
        }

        private void register_item (GLib.DBusConnection conn) {
            try {
                StatusNotifierWatcher watcher = conn.get_proxy_sync (
                    "org.kde.StatusNotifierWatcher",
                    "/StatusNotifierWatcher"
                );
                watcher.register_status_notifier_item ("/StatusNotifierItem");
            } catch (GLib.Error e) {
                GLib.warning ("Failed to register StatusNotifierItem: %s", e.message);
            }
        }

        private void register_dbus () {
            // Vala quirk: without an active session bus, Bus.own_name calls name_lost with conn=null,
            // which trips a fatal assertion failure because vala's lambda expects non-null DBusConnection.
            try {
                GLib.Bus.get_sync (GLib.BusType.SESSION);
            } catch (GLib.Error e) {
                GLib.warning ("No session bus, tray icon disabled: %s", e.message);
                return;
            }
            GLib.Bus.own_name (
                GLib.BusType.SESSION,
                "io.github.dp0sk.Vector.StatusNotifierItem",
                GLib.BusNameOwnerFlags.NONE,
                (conn) => {
                    dbus_conn = conn;
                    try {
                        conn.register_object ("/StatusNotifierItem", item);
                        conn.register_object ("/StatusNotifierMenu", menu);
                        menu.announce_layout ();
                    } catch (GLib.Error e) {
                        GLib.warning ("Failed to export StatusNotifierItem / DBusMenu object: %s", e.message);
                    }
                },
                (conn, name) => {
                    register_item (conn);
                },
                (conn, name) => {
                    GLib.warning ("Lost name io.github.dp0sk.Vector.StatusNotifierItem on DBus");
                }
            );

            GLib.Bus.watch_name (
                GLib.BusType.SESSION,
                "org.kde.StatusNotifierWatcher",
                GLib.BusNameWatcherFlags.NONE,
                (conn, name, owner) => {
                    if (dbus_conn != null) {
                        register_item (dbus_conn);
                    }
                },
                null
            );
        }
    }
}
