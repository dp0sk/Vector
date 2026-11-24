namespace Vector.Ui {

    public class PresetEntryRow : Adw.EntryRow {
        private Gtk.MenuButton preset_btn;
        private Gtk.Popover popover;
        private Gtk.Box pop_box;

        public struct PresetItem {
            public string? name;
            public string value;
            public PresetItem (string? name, string value) {
                this.name = name;
                this.value = value;
            }
        }

        public PresetEntryRow (string title, string initial_text = "", PresetItem[]? presets = null) {
            this.title = title;
            this.text = initial_text;

            preset_btn = new Gtk.MenuButton ();
            preset_btn.icon_name = "pan-down-symbolic";
            preset_btn.tooltip_text = "Select preset";
            preset_btn.add_css_class ("flat");
            preset_btn.valign = Gtk.Align.CENTER;

            popover = new Gtk.Popover ();
            popover.position = Gtk.PositionType.BOTTOM;
            popover.autohide = true;

            pop_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            pop_box.margin_top = 6;
            pop_box.margin_bottom = 6;
            pop_box.margin_start = 6;
            pop_box.margin_end = 6;

            if (presets != null) {
                foreach (var item in presets) {
                    add_preset (item.name, item.value);
                }
            }

            var scroll = new Gtk.ScrolledWindow ();
            scroll.child = pop_box;
            scroll.max_content_height = 320;
            scroll.propagate_natural_height = true;
            scroll.propagate_natural_width = true;

            popover.child = scroll;
            preset_btn.set_popover (popover);
            this.add_suffix (preset_btn);
        }

        public void add_preset (string? name, string val) {
            string label_text = (name != null && name.strip () != "" && name != val) ? "%s (%s)".printf (name, val) : val;
            var b = new Gtk.Button.with_label (label_text);
            b.add_css_class ("flat");
            b.halign = Gtk.Align.FILL;

            var l = b.child as Gtk.Label;
            if (l != null) {
                l.xalign = 0.0f;
                l.wrap = false;
                l.ellipsize = Pango.EllipsizeMode.NONE;
            }

            b.clicked.connect (() => {
                this.text = val;
                popover.popdown ();
            });
            pop_box.append (b);
        }
    }
}
