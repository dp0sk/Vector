namespace Vector.Ui {

    // push text onto default clipboard display
    public class Clipboard {

        public static void copy (string text) {
            var display = Gdk.Display.get_default ();
            if (display != null) {
                display.get_clipboard ().set_text (text);
            }
        }
    }
}
