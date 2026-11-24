// Pure-logic regression tests, built WITHOUT GTK: the logic layer
// (models/, routing/, subscriptions/, engines/, services/, testing/)
// must build and pass on its own. Run with `meson test`.

int failures = 0;

void check (bool ok, string what) {
    if (ok) {
        print ("PASS %s\n", what);
    } else {
        failures++;
        print ("FAIL %s\n", what);
    }
}

int main () {
    var loop = new GLib.MainLoop ();
    run_all.begin ((obj, res) => {
        run_all.end (res);
        loop.quit ();
    });
    loop.run ();
    print (failures == 0 ? "ALL PASS\n" : "%d FAILURES\n".printf (failures));
    return failures == 0 ? 0 : 1;
}

async void run_all () {
    test_node_links ();
    test_hysteria2_links ();
    test_tuic_links ();
    test_wg_multi_peer ();
    test_xray_json ();
    test_xray_json_display ();
    test_config_generation ();
    test_log_formatter ();
    test_subscription_body ();
    test_util ();
    yield test_happ_links ();
}

// Share links

const string VLESS_REALITY =
    "vless://11111111-2222-3333-4444-555555555555@nl1.example.com:443?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=KEYKEYKEYKEYKEYKEYKEYKEYKEYKEYKEYKEYKEYKEYKEYKEYKEY&sid=abcdef12&sni=demo.example.com&fp=chrome#Demo";

void test_node_links () {
    var n = Vector.Models.Node.from_link (VLESS_REALITY, "sub");
    check (n != null, "vless reality parses");
    if (n != null) {
        check (n.protocol == "vless" && n.address == "nl1.example.com" && n.port == 443, "vless fields");
        check (n.reality && n.pbk.has_prefix ("KEYKEYKEY") && n.flow == "xtls-rprx-vision" && n.sni == "demo.example.com", "vless reality fields");
        var back = Vector.Models.Node.from_link (n.to_link () ?? "", "");
        check (back != null && back.address == n.address && back.port == n.port && back.pbk == n.pbk && back.flow == n.flow, "vless share round-trip");
    }

    var a = Vector.Models.Node.from_link (
        "vless://11111111-2222-3333-4444-555555555555@nl1.example.com:443,de2.example.com,fi3.example.com:8443?type=tcp&security=tls#Авто", "");
    check (a != null && a.is_auto () && a.auto_count () == 3, "comma-host parses");
    if (a != null) {
        check (a.auto_hosts == "nl1.example.com:443,de2.example.com:443,fi3.example.com:8443", "host list normalized");
        var back = Vector.Models.Node.from_link (a.to_link () ?? "", "");
        check (back != null && back.auto_hosts == a.auto_hosts, "auto share round-trip");
    }

    var vm = "vmess://" + GLib.Base64.encode (
        "{\"v\":\"2\",\"ps\":\"Demo VMess\",\"add\":\"1.2.3.4\",\"port\":\"443\",\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"net\":\"ws\",\"tls\":\"tls\",\"path\":\"/ws\"}".data);
    var m = Vector.Models.Node.from_link (vm, "");
    check (m != null && m.protocol == "vmess" && m.address == "1.2.3.4" && m.network == "ws" && m.tls, "vmess parses");

    var t = Vector.Models.Node.from_link ("trojan://pass@tj.example.com:443?sni=tj.example.com#Trojan", "");
    check (t != null && t.protocol == "trojan" && t.tls && t.uuid == "pass", "trojan parses");

    check (Vector.Models.Node.from_link ("vless://uuid@:0#x", "") == null, "link without a port is rejected");
    check (Vector.Models.Node.from_link ("not a link", "") == null, "garbage is rejected");
}

// Hysteria 2 & TUIC

void test_hysteria2_links () {
    string uri = "hysteria2://secretpass@hy2.example.com:443?sni=sni.example.com&alpn=h3&obfs=salamander&obfs-password=obfspass#Hy2Node";
    var n = Vector.Models.Node.from_link (uri, "sub");
    check (n != null, "hysteria2 parses");
    if (n != null) {
        check (n.protocol == "hysteria2", "hy2 protocol");
        check (n.address == "hy2.example.com" && n.port == 443, "hy2 host and port");
        check (n.password == "secretpass" && n.uuid == "secretpass", "hy2 password");
        check (n.sni == "sni.example.com" && n.alpn == "h3", "hy2 tls fields");
        check (n.obfs == "salamander" && n.obfs_password == "obfspass", "hy2 obfs fields");
        check (n.name == "Hy2Node", "hy2 name");
        check (n.tls, "hy2 tls default true");
        check (!n.allow_insecure, "hy2 allow_insecure default false");

        var back = Vector.Models.Node.from_link (n.to_link () ?? "", "");
        check (back != null, "hy2 share roundtrip parses");
        if (back != null) {
            check (back.protocol == n.protocol && back.address == n.address && back.port == n.port, "hy2 roundtrip host/port");
            check (back.password == n.password && back.sni == n.sni && back.obfs == n.obfs && back.obfs_password == n.obfs_password, "hy2 roundtrip credentials");
        }
    }

    // hy2:// prefix
    var alt = Vector.Models.Node.from_link ("hy2://pass@hy2alt.example.com:8443#Alt", "");
    check (alt != null && alt.protocol == "hysteria2" && alt.address == "hy2alt.example.com" && alt.port == 8443, "hy2:// prefix parses");
}

void test_tuic_links () {
    string uri = "tuic://11111111-2222-3333-4444-555555555555:tuicpass@tuic.example.com:8443?congestion_control=bbr&udp_relay_mode=native&sni=tuic.example.com&alpn=h3#TuicNode";
    var n = Vector.Models.Node.from_link (uri, "sub");
    check (n != null, "tuic parses");
    if (n != null) {
        check (n.protocol == "tuic", "tuic protocol");
        check (n.address == "tuic.example.com" && n.port == 8443, "tuic host and port");
        check (n.uuid == "11111111-2222-3333-4444-555555555555" && n.password == "tuicpass", "tuic credentials");
        check (n.congestion_control == "bbr" && n.udp_relay_mode == "native", "tuic quic params");
        check (n.sni == "tuic.example.com" && n.alpn == "h3", "tuic tls params");
        check (n.name == "TuicNode", "tuic name");
        check (n.tls, "tuic tls default true");
        check (!n.allow_insecure, "tuic allow_insecure default false");

        var back = Vector.Models.Node.from_link (n.to_link () ?? "", "");
        check (back != null, "tuic share roundtrip parses");
        if (back != null) {
            check (back.protocol == n.protocol && back.address == n.address && back.port == n.port, "tuic roundtrip host/port");
            check (back.uuid == n.uuid && back.password == n.password, "tuic roundtrip credentials");
            check (back.congestion_control == n.congestion_control && back.udp_relay_mode == n.udp_relay_mode, "tuic roundtrip quic params");
        }
    }
}

// Multi-Peer WireGuard / AmneziaWG

const string MULTI_PEER_CONF = """[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
Address = 10.0.0.2/32, fd00::2/128
DNS = 1.1.1.1
MTU = 1280
Jc = 4
Jmin = 50
Jmax = 1000

# Peer One
[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
Endpoint = 198.51.100.1:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25

# Peer Two
[Peer]
PublicKey = cccccccccccccccccccccccccccccccccccccccccccc
Endpoint = 198.51.100.2:51820
AllowedIPs = 0.0.0.0/0, ::/0
""";

void test_wg_multi_peer () {
    string ignored;
    var all = Vector.Models.Node.from_wg_conf_all (MULTI_PEER_CONF, "sub", out ignored);
    check (all.length == 2, "multi-peer conf parses both peers");
    if (all.length == 2) {
        var p1 = all[0];
        var p2 = all[1];
        check (p1.protocol == "awg" && p2.protocol == "awg", "awg protocol recognized from awg params");
        check (p1.name == "Peer One", "first peer comment used as name");
        check (p2.name == "Peer Two", "second peer comment used as name");
        check (p1.address == "198.51.100.1" && p1.port == 51820, "first peer endpoint");
        check (p2.address == "198.51.100.2" && p2.port == 51820, "second peer endpoint");
        check (p1.wg != null && p2.wg != null, "both peers have WgConfig");
        if (p1.wg != null && p2.wg != null) {
            check (p1.wg.private_key == p2.wg.private_key, "shared private key");
            check (p1.wg.local_address == "10.0.0.2/32, fd00::2/128", "shared address");
            check (p1.wg.peer_public_key.has_prefix ("bbbb"), "first peer public key");
            check (p2.wg.peer_public_key.has_prefix ("cccc"), "second peer public key");
            check (p1.wg.awg.size () == 3 && p2.wg.awg.size () == 3, "shared awg params");
        }
    }

    var single = Vector.Models.Node.from_wg_conf (MULTI_PEER_CONF, "sub", out ignored);
    check (single != null && single.name == "Peer One", "from_wg_conf returns first peer");
}

// Whole-config nodes

const string DEMO_CONFIG = """{"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"demo.example.com","port":443,"users":[{"id":"22222222-3333-4444-5555-666666666666","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"demo.example.com","publicKey":"PK1PK1PK1","shortId":"ab"}}}],"routing":{"rules":[]},"remarks":"Demo Auto"}""";

void test_xray_json () {
    var jn = Vector.Models.Node.from_xray_json (DEMO_CONFIG, "sub");
    check (jn != null && jn.is_xray_json (), "xray-json parses");
    if (jn != null) {
        check (jn.name == "Demo Auto" && jn.address == "demo.example.com" && jn.port == 443, "xray-json fields");
        check (jn.protocol == "vless", "xray-json protocol parsed as vless");
        check (jn.network == "tcp" && jn.reality, "xray-json streamSettings parsed");
        check (jn.sni == "demo.example.com" && jn.pbk == "PK1PK1PK1" && jn.sid == "ab", "reality fields parsed");

        // Converts to plaintext vless share link
        string? link = jn.to_link ();
        check (link != null && link.has_prefix ("vless://"), "xray-json converts to plaintext vless share link");
        if (link != null) {
            var back = Vector.Models.Node.from_link (link, "");
            check (back != null && back.protocol == "vless" && back.address == jn.address && back.port == jn.port, "plaintext share link parses back");
            check (back != null && back.reality && back.pbk == "PK1PK1PK1" && back.sid == "ab", "plaintext share link reality roundtrip");
        }

        // Base64 import
        string b64 = GLib.Base64.encode (DEMO_CONFIG.data);
        var from_b64 = Vector.Models.Node.from_link (b64, "");
        check (from_b64 != null && from_b64.is_xray_json () && from_b64.xray_json == jn.xray_json, "base64 config import works");
    }
    check (Vector.Models.Node.from_xray_json ("{\"nothing\": 1}", "") == null, "non-config JSON rejected");
}

// Config generation

void test_xray_json_display () {
    // A mixed-protocol config: the display fields come from the first proxy
    // outbound, whatever protocol it is.
    var body = "[{" +
        "\"outbounds\":[" +
            "{\"tag\":\"proxy\",\"protocol\":\"vless\",\"settings\":{\"vnext\":[{\"address\":\"v.example.com\",\"port\":443,\"users\":[{\"id\":\"11111111-2222-3333-4444-555555555555\",\"encryption\":\"none\"}]}]}}, " +
            "{\"tag\":\"proxy-2\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":1080,\"users\":[{\"user\":\"u\",\"pass\":\"p\"}]}]}}, " +
            "{\"tag\":\"proxy-3\",\"protocol\":\"http\",\"settings\":{\"servers\":[{\"address\":\"h.example.com\",\"port\":3128}] } }, " +
            "{\"tag\":\"proxy-4\",\"protocol\":\"wireguard\",\"settings\":{\"secretKey\":\"SK1\",\"address\":[\"10.8.0.2/32\"],\"mtu\":1420,\"peers\":[{\"publicKey\":\"PK2\",\"preSharedKey\":\"PSK1\",\"allowedIPs\":[\"0.0.0.0/0\",\"::/0\"],\"endpoint\":\"wg.example.com:51820\"}] } }, " +
            "{\"tag\":\"direct\",\"protocol\":\"freedom\"}" +
        "],\"remarks\":\"Mixed\"}]";
    var body_nodes = Vector.Subs.SubscriptionManager.parse_config_body (body, "sub");
    check (body_nodes.length == 1, "mixed config body parses");
    var jn = body_nodes.length > 0 ? (Vector.Models.Node) body_nodes.get (0) : null;
    check (jn != null && jn.is_xray_json () && jn.address == "v.example.com" && jn.port == 443, "mixed config: display from the first proxy outbound");
    check (jn != null && jn.protocol == "vless", "mixed config: protocol is vless");

    // A config whose first proxy outbound is wireguard: the endpoint is the
    // display address.
    var wg_first = "[{\"outbounds\":[" +
        "{\"tag\":\"proxy\",\"protocol\":\"wireguard\",\"settings\":{\"secretKey\":\"SK1\",\"peers\":[{\"publicKey\":\"PK2\",\"endpoint\":\"wg.example.com:51820\"}]}}," +
        "{\"tag\":\"direct\",\"protocol\":\"freedom\"}" +
        "],\"remarks\":\"WG First\"}]";
    var wg_nodes = Vector.Subs.SubscriptionManager.parse_config_body (wg_first, "sub");
    check (wg_nodes.length == 1, "wg-first body parses");
    var w = wg_nodes.length > 0 ? (Vector.Models.Node) wg_nodes.get (0) : null;
    check (w != null && w.protocol == "wireguard" && w.address == "wg.example.com" && w.port == 51820, "wg-first config: endpoint display");
}

void test_config_generation () {
    var s = new Vector.Models.AppSettings ();
    var plain = Vector.Models.Node.from_link (VLESS_REALITY, "");
    if (plain != null) {
        var sb = Vector.Engines.ConfigGenerator.gen_engine_for ("sing-box", plain, 20001, s);
        check (sb.contains ("\"tag\" : \"proxy\"") && !sb.contains ("urltest"), "sing-box plain engine");
        check (sb.contains ("\"server\" : \"nl1.example.com\""), "sing-box server host");
        var xr = Vector.Engines.ConfigGenerator.gen_engine_for ("xray", plain, 20002, s);
        check (xr.contains ("\"tag\" : \"proxy\"") && xr.contains ("realitySettings"), "xray plain engine");
    }

    var auto = Vector.Models.Node.from_link (
        "vless://11111111-2222-3333-4444-555555555555@nl1.example.com:443,de2.example.com:443,fi3.example.com:8443?type=tcp&security=tls#Авто", "");
    if (auto != null) {
        var sba = Vector.Engines.ConfigGenerator.gen_engine_for ("sing-box", auto, 20003, s);
        check (sba.contains ("\"type\" : \"urltest\"") && sba.contains ("proxy-0") && sba.contains ("proxy-2"), "sing-box urltest group for auto");
        var xra = Vector.Engines.ConfigGenerator.gen_engine_for ("xray", auto, 20004, s);
        check (xra.contains ("\"balancers\"") && xra.contains ("leastPing") && xra.contains ("\"observatory\""), "xray balancer for auto");
        // The observatory must sit at the TOP level (inside routing xray
        // silently ignores it and the balancer then fails to start).
        check (has_top_level_key (xra, "observatory"), "xray observatory is top-level");
    }

    var jn = Vector.Models.Node.from_xray_json (DEMO_CONFIG, "");
    if (jn != null) {
        var xe = Vector.Engines.ConfigGenerator.gen_engine_for ("xray", jn, 20005, s);
        check (xe.contains ("\"remarks\"") && xe.contains ("proxy"), "xray-json engine embeds the config");
    }

    var hy = Vector.Models.Node.from_link (
        "hysteria2://pass@hy2.example.com:443?sni=sni.example.com&obfs=salamander&obfs-password=obfspass#Hy2", "");
    if (hy != null) {
        var sb_hy = Vector.Engines.ConfigGenerator.gen_engine_for ("sing-box", hy, 20006, s);
        check (sb_hy.contains ("\"type\" : \"hysteria2\"") && sb_hy.contains ("\"server\" : \"hy2.example.com\""), "sing-box hysteria2 outbound");
        check (sb_hy.contains ("\"password\" : \"pass\"") && sb_hy.contains ("\"salamander\""), "sing-box hysteria2 password and obfs");
    }

    var tc = Vector.Models.Node.from_link (
        "tuic://uuid1:pass1@tuic.example.com:8443?congestion_control=bbr#Tuic", "");
    if (tc != null) {
        var sb_tc = Vector.Engines.ConfigGenerator.gen_engine_for ("sing-box", tc, 20007, s);
        check (sb_tc.contains ("\"type\" : \"tuic\"") && sb_tc.contains ("\"server\" : \"tuic.example.com\""), "sing-box tuic outbound");
        check (sb_tc.contains ("\"uuid\" : \"uuid1\"") && sb_tc.contains ("\"password\" : \"pass1\""), "sing-box tuic credentials");
        check (sb_tc.contains ("\"congestion_control\" : \"bbr\""), "sing-box tuic congestion control");
    }
}

// Tiny extension used only by the tests: is `key` a top-level member?
bool has_top_level_key (string json, string key) {
    try {
        var parser = new Json.Parser ();
        parser.load_from_data (json);
        return parser.get_root () != null
            && parser.get_root ().get_node_type () == Json.NodeType.OBJECT
            && parser.get_root ().get_object ().has_member (key);
    } catch (GLib.Error e) {
        return false;
    }
}

// Log formatting

void test_log_formatter () {
    var fmt = new Vector.Services.LogFormatter ();
    var lines = fmt.process ("\x1b[31mFATAL\x1b[0m [inbound/socks] boom", "core");
    check (lines.length > 0, "log formatter returns lines");
    bool has_ansi = false;
    foreach (var l in lines) {
        if (l.contains ("\x1b[")) has_ansi = true;
    }
    check (!has_ansi, "log formatter strips ANSI codes");
}

// Subscription bodies

void test_subscription_body () {
    var body = "[" + DEMO_CONFIG + ",{\"remarks\":\"B\",\"outbounds\":[{\"tag\":\"proxy\",\"protocol\":\"vless\",\"settings\":{\"vnext\":[{\"address\":\"b.example.com\",\"port\":443,\"users\":[{\"id\":\"33333333-4444-5555-6666-777777777777\",\"encryption\":\"none\"}]}]}}]}]";
    var nodes = Vector.Subs.SubscriptionManager.parse_config_body (body, "u");
    check (nodes.length == 2, "config-array body parses");
    if (nodes.length == 2) {
        check (((Vector.Models.Node) nodes.get (0)).name == "Demo Auto", "first config keeps remarks");
        check (((Vector.Models.Node) nodes.get (1)).address == "b.example.com", "second config address");
    }
}

// Helpers

void test_util () {
    check (Vector.Services.Util.decode_b64 ("aGVsbG8=") != null, "std base64");
    check (Vector.Services.Util.decode_b64 ("aGVsbG8") != null, "unpadded base64");
    check (Vector.Services.Util.decode_b64_bytes ("a-GVsbG8") != null, "url-safe base64");
    var b = Vector.Services.Util.decode_b64 ("aGVsbG8=");
    check (b != null && (string) b == "hello", "base64 decodes");
}

// Happ deep links (encrypted fixture round-trips)

const string HAPP_CRYPT1 = "FXJHcG2UlrO61vKKb88P0bTK56_dZMRg6uBthqvghfGgYWkbp770-u1Gslg0lMlnB1bn3TSrjqXQOeMcmcSlYT8BnTQDr92LBM_br6l4CTs7OYd7zDSKV1Da6AIKqqviwyzZFQwV5mFsJpvRRD684o--ePN8xzsHW6f2tAATlT4";
const string HAPP_CRYPT2 = "VK5gbeHVqJea8hwLUtesiWxluzMA15OYqawwARQuV3uKuWt0e39mOQKsE2dJR_BHPCm2uIqJ-eK2eqO6JSqAzZCzX21IHdmm-hZrK9OtabgG6_MhEBuSV8rBsgenddaCeTKA8UJHvADuKQxfnbcVxZKcv2-62WLDf5VfiRwElRvgUZShR9dsE07OaZRHnzZ4X9DbB7rddt8JoTRMNWb6xL0BSDK_eWf3fnrSThYz8j5Nmjk0FNp2g9ix5YvDyELTcB4iA_zsO-ZMV9JAW4xbAdkyiOPq6LyHjty9B-ZzopY879ZKEw0XgjsKrd_RlZrFkTPcYzrrzReZJRuxuRTwibu1MbNhQkIT8TiP2-BjG0TRfa87mU4-x4CMebMuHP541ldizHKvkmAlhmjPuDpTHZ6uSa-ziuNmcdEvYt2q74FY3_KZho0K2csIPj9MjDRGquyaJccOIiSVhWUEM6Kf5WJVrRIa0q0ec8ChLdxiZ7TjOsMGurHV7JUmWoh14hfI0CCrMgECWDifUNvBu9rVtZqUiMn3BnfLzwiHI-XdWKFkV6FvIrFSaTYTYKa0S1tLcMO3JQA8HzVbosmJeZXpzXuUjJP0wrCaeFPs2rtdXrpBISRu8iThobv4f_LHkS0aOgsAbbZ_LQ8GgyNBB8UpWAlvZXZNiIGuKTvN6RZkxLc";
const string HAPP_CRYPT3 = "kY34xkMEuyA5nzsfwmjSdmsZYxlwTJo5kh-L95_fnZJoUwPo5sqYYa8KkVjb9JV59rateXerZUG2os7evTCA5_AdCJrHQwgbw88IPHSqFRYgrzdCtVFnO7U6HVg5Tt9wvHG_RZhecq2IZ5FUfUZGRVigFaYChxmvDV9oc17tdyH6MVzZ8W4FYUg2qmg14tPpRrU0TNSI3WoVbig81-UdUQEoQgf5YUfdCE6NrAWNtwyfWOaZCPlZILkZWXilAyLSXdrIOHWtdr2_9Ttpm1Tcj13h6zpwCr_vkNpwrWRsOIaHub4QVjItk3rxG2xfWCIKFwVW0u7MdYZFMAK3-lu1xcTSW4d8AhLtMYLKg_1pMoTxWrr1Zlq3tfBKTwyOJOK5yKCsXgfSzzQtxZrBDhBJaMT3zQBWXmm6eqT6ogn9m8onm07CUNzQhrrA93CkCuYeE_PVkdaIWC5gNZ-bHmFbS479dKL1v0_5B8oiVoetO65-oZd8xBf0mtIFPZCHxajuj20dMuaoBnf1pc_cyHq1peSPzKxTBV8NWMjPPu4aV01hoSF2U3niCNlsuI7RZ-lyUrni5hSIDJpiiHYR_kG9LovSOYgt3qFJExm33n9rpxBMM_mXId1zHUwDqnkG2GxeV2HGzIWDbEEKILJ_oGkDYRxazeWLdS30dBMtErNbtxg";
const string HAPP_CRYPT4 = "15BUdRXegO5_JFWvkCivRNN6HV41KxVqXekvTyU7hw2txUtkqSJ2l8lQYNaogBDTaQpmaZHtY9P0lHcItscbIHyVtpV7qpm0VJkGFTQzMpYvSzeq107q45sKJdG_hgV_C5WBT2r7RCh_75xAc6nu86ZWSgGa9dkbPogsydbSJ8DGtelOZHGxcLp8LBOWXSEn-gsQ2Pp4CBL4Ah15PMLHLG-SFY9PZM366CCx9J8s7Wa1gOJKmdtOJsz-Hj-IhmCSeZ6zzQS7CvK5mM9EbTItAarZkcHIx8Gc83rMvJzt0f0GW1zgLqmaWs84s4nEVu3qHika51U5elnezQI-k7CGNWPeAsiBKiQR6v45oGBsdTNH3JCiKSeFdTykOWDjerpHxWrUWc7RY8KhMypFBMEh8HCrK0iBdjQWD6o-jVDpd_UOybz9dRk96Qnykv17RlHGfVKmF46-_ofbA_1AnKCQRZ8AjSTzd86mwoQYGw0_UMsSW6dt9vvcFYuMmspXtXl6IeYEAHVJrgNuqlCCD5Rkg66cD-9jhYpOl-3wlqKTyr0PWItgiHf1dqW7e_s_TrhteH_6mbXfoBJC4u0XlpclAhst9GZm2ywJXnFCO8zWfcIY3ShVDmdUtOUMCoEHBvOUVpHzGGeUgVQdcazWOchn4Nc5cChpNiZ48on7hmL6_J0";
const string HAPP_CRYPT5 = "YWphc1cZ4lAx9i0QmkP6FQFSNzlkbWZLMy03WWZkbDRmZlowWEJTaTUxM2dnWWVTNGcyNzViYVhfZllEQW9NYVA0RmZYc0V5UlNZVlZjVjBibWJIa3ZkYjBvV0d0SjdDd25BNGhYSlV1MlhwRnR4V0tRUUU4alJ1bnJmS2F0UjJfSWpDanJ2SHphYnJISVI0cGktbF9Sa3dGWE91TE9lNUVFR3YxUFZlTFZOZDg5TXRmdGRLNDJ4RzJsQTgydldPSFlaS19DSEwwaUNkOEVwel9TMVhmaG84TzFaWVBVdHV0YjViTXk1dHd2RzhmczZtNXByRmIzWnhRQ25nYXRXUFU4OEZqTDdjVU9FQWwtdC1GemJKa2ZvVnlkSDAwRkE2Wk45RDYyWU91UG9fZ3ZOUExMbGptQV9mNWdhci10S1lCR0VqRGJocmxiTzhQUzhQUkw2TjFIWEptZzhsTk9KRmVLSjV3amRiVnB6emFsR0lhekpSQ29paWUxOEhWcnQwSG1NYW5Jd3JJemlfRkFxZGdwYTZWSWhubFo1bmZfa3hreVp3ZU1QZ2xaN2ZyWE5rbS1yZi1ZaV9XM0V3MjJXMkdsNmt2S0FGUExXbjBlY1lwWkhaRU5qb1pWWUJYMFVhUXdrMjJROG1zNThzaVY0aWdGd0dMS3RPQnMxM2tfVllsY25zUDB1Q1NydW5kV2RpV3ZTTFVDTUs3UlUyZDd5RFV4X3NvNFR5VTVVZ1ZwNDJtb3hQSHg5b0NnTkFxY1JFWjdXaW5XOEFyT1dScEtvUURPSTJKenhBNlBRMjNIdHJzbXpwRFhRNWh5RWVmQ0EzY1BpWFdfajloTjUyTkljNWdVVG1TeEF5X2pRUW1qY3hETEthbmoxRkVpNVQ2enN4cFVyUEtNRElZSnIzSnphUVFvR0QyRHhIeVFXTWZsMzUxNEtrME5jbmJQWTdqR1V0VkpiQ1h6Q015R0dQenN5VEdfQXE4Y282TXBkVFNkRHZYM1Vvd0kzNG9GNmN6dHlpQjJXZDgta3J0bWxucXhJenQ";
const string HAPP_CRYPT5_SALTED = "YWphc8a9HFvf_N6YsZfWIw4kAADjDJRXOTFC3XVWAUhnMmVKbGZpZHp2MHJmNWtLTUhkaWYyR1VweFVfZWNjQm5WZU5UVlQ3bVhUYzdhQXUyTHZGSkxiaGlTeGQwXzBYbTNaNEZSajE4UnJINXpqek1KZDZWMDlldHRUZEFzNkVtUmlEZERhMHVmZV9nN0ZZTU9IUW9lYkdXMnZOQXpoNHVZd1ZFOUN3SG1MeWxHOHNwOGNXQTNWQXlUZ2YzcWRXOUcwcm9qM1h5cnpJV3NoTnpmcmZzZVI4ak1fRHM2RGxHM1FkRkQxbG15UzY0YUFJYzlmbVBOMUZFTE92QzF6LUptY1hnNWpvak05Wk8wVVJVbVFLeXVaTGRYZFlhallyTjQxOUlCRER0SWg5SXRLX1FoS2EtTkVORnZwNWJ5SGdVRk5vQm9tVmhKd0Y2eDZtdV9iZHdycWNfWjhmb3Rrc3pxdTZyanl5SVFmbGpBQkNncFVRTGVyUVZvV2t3VTRYY3h1VzRwRTFsZnEwQjBFakUwZ3h3Zml5MWlrcmpWd3lSdlRUNWZSVUQ4U2dud0VtVENfU2d0dGE0YmdtcHJaRFVGY1BiOFRpcTJReTIxNkRJVk9TWEZCM29WUE1VTmUyT2hKRDhpMHJtQnltZFRYZ25yWnlsWDJPN2RieURsdGZpNXo4a0MzWFdPVkZUbUtiemRvdklGWkh1TnJ2QzRsRURoN3lsTmhJN0FyTmNuQ19DVXRSU01YNUF1dGR3U05ic0Y2VlpvWG1fTTJHeTdWZzczMTVYeE5CeXhPYnB5SXg0cFQ2VnBFTnZ1eVkwMjJRZHJYLVdrYTBCdzhMQ0lYRGIxUWFNQTE2UFRxVkc5bDI0THFscWZaTjN5VjJNM2EzbXJtRmhBR0pQTHYtelFhQi1fVFNjb3RnWGNacTRLMHl3OVhLeDFiNkJvVWVzR3pBbjNXOVN0NjJaYUFvUDFmZFZ4Y3dHZWlXeGlVZTZxRGMzMFpYemtac2tGMGtXWW40cmY1aGEzcnJXX1JYdV9uTGl5d2NBZkt0RG0yYjNTeWVRenVYcXh0";

async void test_happ_links () {
    // [link, expected plaintext] pairs: generated by encrypting with the
    // matching public key (fixtures, not real provider data).
    var cases = new string[,] {
        { "happ://crypt/" + HAPP_CRYPT1, "https://sub.example.com/v1-token" },
        { "happ://crypt2/" + HAPP_CRYPT2, "https://sub.example.com/v2-token" },
        { "happ://crypt3/" + HAPP_CRYPT3, "https://sub.example.com/v3-token" },
        { "happ://crypt4/" + HAPP_CRYPT4, "https://sub.example.com/v4-token" },
        { "happ://crypt5/" + HAPP_CRYPT5, "https://sub.example.com/c5-token" },
        { "happ://crypt5/" + HAPP_CRYPT5_SALTED, "https://sub.example.com/c5-salted-token" }
    };
    for (int i = 0; i < cases.length[0]; i++) {
        try {
            var got = yield Vector.Subs.HappLink.decrypt (cases[i, 0]);
            check (got == cases[i, 1], "happ decrypt %d".printf (i + 1));
        } catch (Vector.Subs.HappLinkError e) {
            check (false, "happ decrypt %d (%s)".printf (i + 1, e.message));
        }
    }
    // A wrong marker/payload must fail loudly, not decrypt to junk.
    try {
        yield Vector.Subs.HappLink.decrypt ("happ://crypt5/!!!!");
        check (false, "crypt5 junk rejected");
    } catch (Vector.Subs.HappLinkError e) {
        check (true, "crypt5 junk rejected");
    }
}
