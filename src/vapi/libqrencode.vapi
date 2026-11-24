// Minimal binding for libqrencode (qrencode.h): only what Util.qr_texture uses.
[CCode (cheader_filename = "qrencode.h")]
namespace QR {
    [CCode (cname = "QRecLevel", cprefix = "QR_ECLEVEL_", has_type_id = false)]
    public enum ECLevel { L, M, Q, H }

    [CCode (cname = "QRencodeMode", has_type_id = false)]
    public enum Mode {
        [CCode (cname = "QR_MODE_8")]
        EIGHT_BIT
    }

    // A square of `width` x `width` modules; bit 0 of each byte = dark.
    [Compact, CCode (cname = "QRcode", free_function = "QRcode_free")]
    public class Code {
        public int version;
        public int width;
        [CCode (array_length = false)]
        public uint8[] data;

        [CCode (cname = "QRcode_encodeString")]
        public static Code? encode_string (string text, int version, ECLevel level, Mode hint, int case_sensitive);
    }
}
