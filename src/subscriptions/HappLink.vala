using Vector.Services;
namespace Vector.Subs {

    // happ://crypt... deep links: Happ obfuscates sub URLs with hardcoded RSA keys dumped
    // from their APK/app. Keys in data/happ-keys.json were extracted by the community.
    //
    // Generations:
    //  crypt/ through crypt4/: straight RSA PKCS#1 v1.5 over key-size chunks.
    //  crypt5/: Happ v5 format. Swaps block halves, matches marker bytes to pick
    //           an RSA key, decrypts ChaCha20 key (optionally XOR-salted),
    //           then runs ChaCha20-Poly1305 over the base64 payload.
    public errordomain HappLinkError {
        NOT_A_HAPP_LINK, BAD_PAYLOAD, MISSING_KEY, UNKNOWN_MARKER, RSA_FAILED, AUTH_FAILED, BAD_FORMAT
    }

    public class HappLink : GLib.Object {

        // static array field in Vala doesn't initialize properly without a class instance,
        // so use a dumb switch to avoid segfaults
        private static int block_size (int ordinal) {
            switch (ordinal) {
                case 0: return 128;
                default: return 512;
            }
        }

        private static Json.Object? keys; // cached from gresource

        public static bool is_happ_link (string text) {
            string t = text.strip ();
            return t.has_prefix ("happ://crypt/") || t.has_prefix ("happ://crypt2/")
                || t.has_prefix ("happ://crypt3/") || t.has_prefix ("happ://crypt4/")
                || t.has_prefix ("happ://crypt5/");
        }

        public async static string decrypt (string link) throws HappLinkError {
            string t = link.strip ();
            int gen = 0;
            string payload = "";
            if (t.has_prefix ("happ://crypt5/"))      { gen = 5; payload = t.substring (14); }
            else if (t.has_prefix ("happ://crypt4/")) { gen = 4; payload = t.substring (14); }
            else if (t.has_prefix ("happ://crypt3/")) { gen = 3; payload = t.substring (14); }
            else if (t.has_prefix ("happ://crypt2/")) { gen = 2; payload = t.substring (14); }
            else if (t.has_prefix ("happ://crypt/"))  { gen = 1; payload = t.substring (13); }
            else {
                throw new HappLinkError.NOT_A_HAPP_LINK ("not a happ://crypt link");
            }

            uint8[] cipher = decode_b64 (payload);
            if (cipher == null || cipher.length == 0) {
                throw new HappLinkError.BAD_PAYLOAD ("invalid happ link payload");
            }

            if (gen < 5) return yield decrypt_v1_4 (gen - 1, cipher);
            return yield decrypt_v5 (cipher);
        }

        // crypt1..4: basic RSA chunking. openssl CLI handles PKCS#1 v1.5 padding
        private async static string decrypt_v1_4 (int ordinal, uint8[] cipher) throws HappLinkError {
            string? key_b64 = key_for ("v%d".printf (ordinal + 1));
            if (key_b64 == null) {
                throw new HappLinkError.MISSING_KEY ("missing happ key");
            }
            int block = block_size (ordinal);
            var plain = new GLib.ByteArray ();
            for (int off = 0; off < cipher.length; off += block) {
                int len = int.min (block, cipher.length - off);
                var part = new uint8[len];
                for (int i = 0; i < len; i++) part[i] = cipher[off + i];
                uint8[] piece = yield rsa_decrypt (part, key_b64, "RSA PRIVATE KEY");
                plain.append (piece);
            }
            plain.append ({ '\0' });
            string result = (string) plain.data;
            if (!result.validate ()) throw new HappLinkError.BAD_PAYLOAD ("decrypted text is not valid UTF-8");
            return result;
        }

        // crypt5: block swaps, marker lookups, and ChaCha20-Poly1305 AEAD
        private async static string decrypt_v5 (uint8[] cipher) throws HappLinkError {
            uint8[] shuffled = swap_block_halves (cipher);
            if (shuffled.length < 8) {
                throw new HappLinkError.BAD_PAYLOAD ("crypt5 payload too short");
            }
            string marker_s = ascii_str (shuffled[0:4]) + ascii_str (shuffled[shuffled.length - 4:shuffled.length]);
            string? key_b64 = marker_key (marker_s);
            if (key_b64 == null) {
                throw new HappLinkError.UNKNOWN_MARKER ("unknown crypt5 marker");
            }
            uint8[] body = shuffled[4:shuffled.length - 4];
            bool prefer_salted = body.length > 12 && !(body[12] >= 48 && body[12] <= 57);
            HappLinkError? first_error = null;
            foreach (bool salted in new bool[] { prefer_salted, !prefer_salted }) {
                try {
                    return yield decrypt_v5_body (body, key_b64, salted);
                } catch (HappLinkError e) {
                    if (first_error == null) first_error = e;
                }
            }
            throw first_error ?? new HappLinkError.BAD_FORMAT ("crypt5 decryption failed");
        }

        private async static string decrypt_v5_body (uint8[] body, string key_b64, bool salted) throws HappLinkError {
            if (body.length < 13) {
                throw new HappLinkError.BAD_PAYLOAD ("crypt5 body too short");
            }
            uint8[] nonce = body[0:12];
            uint8[] salt = null;
            int length_start = 12;
            if (salted) {
                if (body.length < 22) {
                    throw new HappLinkError.BAD_PAYLOAD ("crypt5 salted header too short");
                }
                salt = body[14:22];
                length_start = 22;
            }
            int length_end = length_start;
            while (length_end < body.length && body[length_end] >= 48 && body[length_end] <= 57) length_end++;
            if (length_end == length_start) {
                throw new HappLinkError.BAD_FORMAT ("crypt5 segment length missing");
            }
            int segment_length = int.parse (ascii_str (body[length_start:length_end]));
            uint8[] packed = body[length_end:body.length];
            if (segment_length <= 0 || packed.length == 0 || segment_length > packed.length - 1) {
                throw new HappLinkError.BAD_FORMAT ("crypt5 segment truncated");
            }
            string encrypted_url_s = ascii_str (packed[1:1 + segment_length]);
            uint8[] rsa_cipher = decode_b64 (ascii_str (packed[1 + segment_length:packed.length]));
            if (rsa_cipher == null) {
                throw new HappLinkError.BAD_PAYLOAD ("invalid crypt5 RSA segment");
            }
            uint8[] rsa_plain = yield rsa_decrypt (rsa_cipher, key_b64, "PRIVATE KEY");
            uint8[] rsa_value = decode_b64 (ascii_str (swap_adjacent (rsa_plain)));
            if (rsa_value == null || rsa_value.length != 32) {
                throw new HappLinkError.BAD_FORMAT ("unexpected crypt5 key length");
            }
            var chacha_key = new uint8[32];
            for (int i = 0; i < 32; i++) {
                chacha_key[i] = rsa_value[i];
                if (salt != null) chacha_key[i] ^= salt[i % salt.length];
            }
            uint8[] ct = decode_b64 (encrypted_url_s);
            if (ct == null) {
                throw new HappLinkError.BAD_PAYLOAD ("invalid crypt5 payload segment");
            }
            uint8[] intermediate = chacha20_poly1305_decrypt (chacha_key, nonce, ct);
            if (intermediate == null) {
                throw new HappLinkError.AUTH_FAILED ("crypt5 authentication failed");
            }
            uint8[] plain = decode_b64 (ascii_str (swap_adjacent (intermediate)));
            if (plain == null) {
                throw new HappLinkError.BAD_PAYLOAD ("invalid crypt5 plaintext");
            }
            string s = ascii_str (plain);
            if (!s.validate ()) throw new HappLinkError.BAD_PAYLOAD ("decrypted text is not valid UTF-8");
            return s;
        }

        // GLib doesn't have RSA PKCS#1 v1.5 decryption built-in, so pipe through openssl pkeyutl.
        // Drops temporary 0600 PEM file into runtime dir and unlinks it immediately after
        private async static uint8[] rsa_decrypt (uint8[] block, string key_b64, string pem_label) throws HappLinkError {
            string pem = GLib.Path.build_filename (Paths.runtime_dir (),
                "happ-key-%u.pem".printf ((uint) GLib.get_monotonic_time ()));
            try {
                var sb = new GLib.StringBuilder ();
                sb.append_printf ("-----BEGIN %s-----\n", pem_label);
                for (int i = 0; i < key_b64.length; i += 64) {
                    sb.append (key_b64[i:int.min (i + 64, key_b64.length)]);
                    sb.append_c ('\n');
                }
                sb.append_printf ("-----END %s-----\n", pem_label);
                Util.write_private (pem, sb.str);

                var proc = new GLib.Subprocess (
                    GLib.SubprocessFlags.STDIN_PIPE | GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_SILENCE,
                    "openssl", "pkeyutl", "-decrypt", "-inkey", pem);
                GLib.Bytes? out_bytes = null, err_bytes = null;
                yield proc.communicate_async (new GLib.Bytes.static (block), null, out out_bytes, out err_bytes);
                if (!proc.get_if_exited () || proc.get_exit_status () != 0) {
                    throw new HappLinkError.RSA_FAILED ("openssl pkeyutl failed with exit status %d".printf (proc.get_exit_status ()));
                }
                return out_bytes.get_data ();
            } catch (HappLinkError e) {
                throw e;
            } catch (GLib.Error e) {
                throw new HappLinkError.RSA_FAILED (e.message);
            } finally {
                GLib.FileUtils.unlink (pem);
            }
        }

        // v1..v4 are plain base64 strings in happ-keys.json
        private static string? key_for (string version) {
            try {
                var root = ensure_keys ();
                if (!root.has_member (version)) return null;
                var v = root.get_member (version);
                return v.get_node_type () == Json.NodeType.VALUE ? v.get_string () : null;
            } catch (GLib.Error e) {
                return null;
            }
        }

        // v5 has a dictionary mapping 8-char marker strings to private keys
        private static string? marker_key (string marker) {
            try {
                var root = ensure_keys ();
                if (!root.has_member ("v5")) return null;
                var v = root.get_member ("v5");
                if (v.get_node_type () != Json.NodeType.OBJECT) return null;
                var table = v.get_object ();
                return table.has_member (marker) ? table.get_string_member (marker) : null;
            } catch (GLib.Error e) {
                return null;
            }
        }

        private static Json.Object ensure_keys () throws GLib.Error {
            if (keys == null) {
                var bytes = GLib.resources_lookup_data (
                    "/io/github/dp0sk/Vector/happ-keys.json", GLib.ResourceLookupFlags.NONE);
                uint8[] data = bytes.get_data ();
                data += '\0';
                var parser = new Json.Parser ();
                parser.load_from_data ((string) data);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    throw new GLib.IOError.INVALID_DATA ("happ-keys.json: not an object");
                }
                keys = root.get_object ();
            }
            return keys;
        }

        // lenient base64 decode: fix url-safe chars (-_), strip whitespace/newlines, pad with '='
        private static uint8[]? decode_b64 (string s) {
            var clean = new GLib.StringBuilder ();
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
                if (c == '-') clean.append_c ('+');
                else if (c == '_') clean.append_c ('/');
                else clean.append_c (c);
            }
            int end = (int) clean.len;
            while (end > 0 && clean.str[end - 1] == '=') end--;
            clean.truncate (end);
            while (clean.len % 4 != 0) clean.append_c ('=');
            if (clean.len == 0) return null;
            return GLib.Base64.decode (clean.str);
        }

        private static uint8[] swap_adjacent (uint8[] b) {
            var r = new uint8[b.length];
            for (int i = 0; i + 1 < b.length; i += 2) {
                r[i] = b[i + 1];
                r[i + 1] = b[i];
            }
            if (b.length % 2 == 1) r[b.length - 1] = b[b.length - 1];
            return r;
        }

        // Happ byte shuffle: swaps halves of every 4-byte block (ABCD -> CDAB)
        private static uint8[] swap_block_halves (uint8[] b) {
            var r = new uint8[b.length];
            for (int i = 0; i < b.length; i++) r[i] = b[i];
            int full = b.length - (b.length % 4);
            for (int i = 0; i < full; i += 4) {
                r[i] = b[i + 2];
                r[i + 1] = b[i + 3];
                r[i + 2] = b[i];
                r[i + 3] = b[i + 1];
            }
            return r;
        }

        private static string ascii_str (uint8[] b) {
            var r = new uint8[b.length + 1];
            for (int i = 0; i < b.length; i++) r[i] = b[i];
            return (string) r;
        }

        // ChaCha20-Poly1305 (RFC 8439) in pure Vala because linking libsodium for one link type is overkill
        private static uint8[]? chacha20_poly1305_decrypt (uint8[] key, uint8[] nonce, uint8[] ct) {
            if (key.length != 32 || nonce.length != 12 || ct.length < 16) return null;
            uint8[] cipher = ct[0:ct.length - 16];
            uint8[] tag = ct[ct.length - 16:ct.length];

            // One-time Poly1305 key from block counter 0.
            uint8[] otk_full = chacha_block (key, nonce, 0);
            uint8[] otk = otk_full[0:32];

            // mac_data = ct || pad16 || le64(aad_len = 0) || le64(ct_len)
            var mac_data = new uint8[cipher.length + 31];
            for (int i = 0; i < cipher.length; i++) mac_data[i] = cipher[i];
            int pad = 16 - (cipher.length % 16);
            int mac_len = cipher.length + (pad == 16 ? 0 : pad) + 16;
            for (int i = 0; i < 8; i++) mac_data[mac_len - 8 + i] = (uint8) ((uint64) cipher.length >> (8 * i));

            uint8[] calc = new uint8[16];
            poly1305_mac (otk, mac_data[0:mac_len], calc);
            int diff = 0;
            for (int i = 0; i < 16; i++) diff |= calc[i] ^ tag[i];
            if (diff != 0) return null;

            // Keystream starts at block counter 1.
            var plain = new uint8[cipher.length];
            uint32 counter = 1;
            for (int off = 0; off < cipher.length; off += 64) {
                uint8[] ks = chacha_block (key, nonce, counter++);
                for (int i = 0; i < 64 && off + i < cipher.length; i++) plain[off + i] = cipher[off + i] ^ ks[i];
            }
            return plain;
        }

        private static uint32 le32 (uint8[] b, int off) {
            return (uint32) b[off] | ((uint32) b[off + 1] << 8) | ((uint32) b[off + 2] << 16) | ((uint32) b[off + 3] << 24);
        }

        private static void put_le32 (uint8[] b, int off, uint32 v) {
            b[off] = (uint8) v;
            b[off + 1] = (uint8) (v >> 8);
            b[off + 2] = (uint8) (v >> 16);
            b[off + 3] = (uint8) (v >> 24);
        }

        private static uint32 rotl (uint32 v, int n) {
            return (v << n) | (v >> (32 - n));
        }

        private static void qr (ref uint32 a, ref uint32 b, ref uint32 c, ref uint32 d) {
            a += b; d ^= a; d = rotl (d, 16);
            c += d; b ^= c; b = rotl (b, 12);
            a += b; d ^= a; d = rotl (d, 8);
            c += d; b ^= c; b = rotl (b, 7);
        }

        // One 64-byte ChaCha20 block for (key, nonce, counter).
        private static uint8[] chacha_block (uint8[] key, uint8[] nonce, uint32 counter) {
            uint32[] s = new uint32[16];
            s[0] = 0x61707865; s[1] = 0x3320646e; s[2] = 0x79622d32; s[3] = 0x6b206574;
            for (int i = 0; i < 8; i++) s[4 + i] = le32 (key, i * 4);
            s[12] = counter;
            s[13] = le32 (nonce, 0);
            s[14] = le32 (nonce, 4);
            s[15] = le32 (nonce, 8);
            uint32[] x = new uint32[16];
            for (int i = 0; i < 16; i++) x[i] = s[i];
            for (int round = 0; round < 10; round++) {
                qr (ref x[0], ref x[4], ref x[8], ref x[12]);
                qr (ref x[1], ref x[5], ref x[9], ref x[13]);
                qr (ref x[2], ref x[6], ref x[10], ref x[14]);
                qr (ref x[3], ref x[7], ref x[11], ref x[15]);
                qr (ref x[0], ref x[5], ref x[10], ref x[15]);
                qr (ref x[1], ref x[6], ref x[11], ref x[12]);
                qr (ref x[2], ref x[7], ref x[8], ref x[13]);
                qr (ref x[3], ref x[4], ref x[9], ref x[14]);
            }
            var result = new uint8[64];
            for (int i = 0; i < 16; i++) put_le32 (result, i * 4, x[i] + s[i]);
            return result;
        }

        // Poly1305 (the poly1305-donna 26-bit limb layout), key = 32 bytes.
        private static void poly1305_mac (uint8[] key, uint8[] msg, uint8[] tag) {
            uint32 r0, r1, r2, r3, r4;
            uint32 s1, s2, s3, s4;
            uint32 h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;

            uint32 t0 = le32 (key, 0), t1 = le32 (key, 4), t2 = le32 (key, 8), t3 = le32 (key, 12);
            r0 = t0 & 0x3ffffff;
            r1 = ((t0 >> 26) | (t1 << 6)) & 0x3ffff03;
            r2 = ((t1 >> 20) | (t2 << 12)) & 0x3ffc0ff;
            r3 = ((t2 >> 14) | (t3 << 18)) & 0x3f03fff;
            r4 = (t3 >> 8) & 0x00fffff;
            s1 = r1 * 5; s2 = r2 * 5; s3 = r3 * 5; s4 = r4 * 5;

            var buf = new uint8[16];
            int i = 0;
            while (i < msg.length) {
                int remaining = msg.length - i;
                uint32 hibit;
                if (remaining >= 16) {
                    for (int k = 0; k < 16; k++) buf[k] = msg[i + k];
                    i += 16;
                    hibit = 1u << 24;
                } else {
                    for (int k = 0; k < 16; k++) buf[k] = 0;
                    for (int k = 0; k < remaining; k++) buf[k] = msg[i + k];
                    buf[remaining] = 1;
                    i = msg.length;
                    hibit = 0;
                }
                h0 += le32 (buf, 0) & 0x3ffffff;
                h1 += (le32 (buf, 3) >> 2) & 0x3ffffff;
                h2 += (le32 (buf, 6) >> 4) & 0x3ffffff;
                h3 += (le32 (buf, 9) >> 6) & 0x3ffffff;
                h4 += (le32 (buf, 12) >> 8) | hibit;

                // h *= r (mod 2^130 - 5)
                uint64 d0 = (uint64) h0 * r0 + (uint64) h1 * s4 + (uint64) h2 * s3 + (uint64) h3 * s2 + (uint64) h4 * s1;
                uint64 d1 = (uint64) h0 * r1 + (uint64) h1 * r0 + (uint64) h2 * s4 + (uint64) h3 * s3 + (uint64) h4 * s2;
                uint64 d2 = (uint64) h0 * r2 + (uint64) h1 * r1 + (uint64) h2 * r0 + (uint64) h3 * s4 + (uint64) h4 * s3;
                uint64 d3 = (uint64) h0 * r3 + (uint64) h1 * r2 + (uint64) h2 * r1 + (uint64) h3 * r0 + (uint64) h4 * s4;
                uint64 d4 = (uint64) h0 * r4 + (uint64) h1 * r3 + (uint64) h2 * r2 + (uint64) h3 * r1 + (uint64) h4 * r0;

                uint64 c;
                c = d0 >> 26; h0 = (uint32) (d0 & 0x3ffffff);
                d1 += c; c = d1 >> 26; h1 = (uint32) (d1 & 0x3ffffff);
                d2 += c; c = d2 >> 26; h2 = (uint32) (d2 & 0x3ffffff);
                d3 += c; c = d3 >> 26; h3 = (uint32) (d3 & 0x3ffffff);
                d4 += c; c = d4 >> 26; h4 = (uint32) (d4 & 0x3ffffff);
                h0 += (uint32) c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
                h1 += (uint32) c;
            }

            // Fully carry h, then select h or h - (2^130 - 5).
            uint32 c2 = h1 >> 26; h1 &= 0x3ffffff;
            h2 += c2; c2 = h2 >> 26; h2 &= 0x3ffffff;
            h3 += c2; c2 = h3 >> 26; h3 &= 0x3ffffff;
            h4 += c2; c2 = h4 >> 26; h4 &= 0x3ffffff;
            h0 += c2 * 5; c2 = h0 >> 26; h0 &= 0x3ffffff;
            h1 += c2;

            uint32 g0 = h0 + 5; c2 = g0 >> 26; g0 &= 0x3ffffff;
            uint32 g1 = h1 + c2; c2 = g1 >> 26; g1 &= 0x3ffffff;
            uint32 g2 = h2 + c2; c2 = g2 >> 26; g2 &= 0x3ffffff;
            uint32 g3 = h3 + c2; c2 = g3 >> 26; g3 &= 0x3ffffff;
            uint32 g4 = h4 + c2 - (1u << 26);

            uint32 mask = (g4 >> 31) - 1u;
            uint32 nmask = ~mask;
            h0 = (h0 & nmask) | (g0 & mask);
            h1 = (h1 & nmask) | (g1 & mask);
            h2 = (h2 & nmask) | (g2 & mask);
            h3 = (h3 & nmask) | (g3 & mask);
            h4 = (h4 & nmask) | (g4 & mask);

            // h = h % 2^128, then add the second half of the key.
            uint32 w0 = h0 | (h1 << 26);
            uint32 w1 = (h1 >> 6) | (h2 << 20);
            uint32 w2 = (h2 >> 12) | (h3 << 14);
            uint32 w3 = (h3 >> 18) | (h4 << 8);

            uint64 f;
            f = (uint64) w0 + le32 (key, 16); put_le32 (tag, 0, (uint32) f);
            f = (uint64) w1 + le32 (key, 20) + (f >> 32); put_le32 (tag, 4, (uint32) f);
            f = (uint64) w2 + le32 (key, 24) + (f >> 32); put_le32 (tag, 8, (uint32) f);
            f = (uint64) w3 + le32 (key, 28) + (f >> 32); put_le32 (tag, 12, (uint32) f);
        }
    }
}
