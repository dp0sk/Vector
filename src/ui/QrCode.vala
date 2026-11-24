namespace Vector.Ui {

    // render QR code straight into a GdkMemoryTexture via libqrencode (6px modules + 2-module quiet zone)
    public class QrCode {

        public static Gdk.Texture texture (string text) throws GLib.Error {
            var code = QR.Code.encode_string (text, 0, QR.ECLevel.M, QR.Mode.EIGHT_BIT, 1);
            if (code == null) throw new GLib.IOError.FAILED ("could not encode the QR code");
            const int SCALE = 6;
            const int MARGIN = 2;
            int modules = code.width;
            int size = (modules + 2 * MARGIN) * SCALE;
            var pixels = new uint8[size * size];
            GLib.Memory.set (pixels, 0xff, pixels.length);
            for (int y = 0; y < modules; y++) {
                for (int x = 0; x < modules; x++) {
                    if ((code.data[y * modules + x] & 1) == 0) continue;
                    for (int dy = 0; dy < SCALE; dy++) {
                        int row = ((y + MARGIN) * SCALE + dy) * size + (x + MARGIN) * SCALE;
                        for (int dx = 0; dx < SCALE; dx++) pixels[row + dx] = 0;
                    }
                }
            }
            return new Gdk.MemoryTexture (size, size, Gdk.MemoryFormat.G8, new GLib.Bytes (pixels), size);
        }
    }
}
