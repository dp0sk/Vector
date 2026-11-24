namespace Vector.Services {

    // shared http client for subscriptions and geo assets.
    public class HttpClient : GLib.Object {

        public const string USER_AGENT = "Vector/2.0";

        private static Soup.Session? proxied_session = null;
        private static Soup.Session? direct_session = null;

        private static Soup.Session session (bool direct) {
            if (direct) {
                if (direct_session == null) {
                    // libsoup quirk: pass proxy-resolver = null explicitly to bypass system proxy
                    direct_session = (Soup.Session) GLib.Object.new (typeof (Soup.Session), "proxy-resolver", null);
                }
                return direct_session;
            }
            if (proxied_session == null) {
                proxied_session = new Soup.Session ();
            }
            return proxied_session;
        }

        // libsoup quirk: set default User-Agent on the message itself, NOT the session!
        // If set on session, libsoup stubbornly overrides custom UA headers passed by caller.
        public static async GLib.Bytes fetch (string url, bool direct = false, string[]? headers = null,
                                            uint timeout_sec = 30) throws GLib.Error {
            var msg = new Soup.Message ("GET", url);
            if (msg == null) throw new GLib.IOError.INVALID_ARGUMENT ("invalid URL: %s".printf (url));
            msg.request_headers.replace ("User-Agent", USER_AGENT);
            if (headers != null) {
                foreach (var h in headers) {
                    int colon = h.index_of (":");
                    if (colon > 0) msg.request_headers.replace (h.substring (0, colon).strip (), h.substring (colon + 1).strip ());
                }
            }
            var cancel = new GLib.Cancellable ();
            uint timer = 0;
            timer = GLib.Timeout.add_seconds (timeout_sec, () => {
                timer = 0;
                cancel.cancel ();
                return GLib.Source.REMOVE;
            });
            try {
                var bytes = yield session (direct).send_and_read_async (msg, GLib.Priority.DEFAULT, cancel);
                if (msg.status_code < 200 || msg.status_code >= 300) {
                    throw new GLib.IOError.FAILED ("HTTP %u for %s".printf (msg.status_code, url));
                }
                return bytes;
            } catch (GLib.IOError.CANCELLED e) {
                throw new GLib.IOError.TIMED_OUT ("timed out after %us: %s".printf (timeout_sec, url));
            } finally {
                if (timer != 0) GLib.Source.remove (timer);
            }
        }
    }
}
