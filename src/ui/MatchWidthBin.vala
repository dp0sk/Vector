namespace Vector.Ui {

    // GTK4 STILL doesn't have a max-width CSS property or widget attribute.
    // This dirty bin widget measures a sibling/target widget, scales it by factor,
    // and caps child natural width against it so wide layouts don't blow up.
    public class MatchWidthBin : Gtk.Widget {

        private Gtk.Widget child;
        private Gtk.Widget? _match = null;

        public Gtk.Widget? match {
            get { return _match; }
            set { _match = value; queue_resize (); }
        }

        private double _factor = 1.0;

        public double factor {
            get { return _factor; }
            set { _factor = value; queue_resize (); }
        }

        public MatchWidthBin (Gtk.Widget child) {
            this.child = child;
            child.set_parent (this);
        }

        public override Gtk.SizeRequestMode get_request_mode () {
            return Gtk.SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Gtk.Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            child.measure (orientation, for_size, out minimum, out natural,
                           out minimum_baseline, out natural_baseline);
            if (orientation == Gtk.Orientation.HORIZONTAL && _match != null && _match.visible) {
                int m_min, m_nat;
                _match.measure (orientation, -1, out m_min, out m_nat, null, null);
                natural = int.max (natural, (int) (m_nat * _factor));
            }
        }

        public override void size_allocate (int width, int height, int baseline) {
            child.allocate (width, height, baseline, null);
        }

        public override void dispose () {
            if (child != null) {
                child.unparent ();
                child = null;
            }
            base.dispose ();
        }
    }
}
