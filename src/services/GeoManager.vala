using Vector.Models;
using Vector.Engines;
namespace Vector.Services {

    // pulls geoip/geosite databases for xray (.dat) or sing-box (.srs binary rule-sets)
    public class GeoManager : GLib.Object {

        private const string LOYALSOLDIER = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/";

        public async string update (string core, AppSettings settings, Store store) throws GLib.Error {
            switch (core) {
                case "xray":     return yield update_dat_files (settings.geo_files_source.strip ());
                case "sing-box": return yield update_rule_sets (settings, store);
                default:         return "Unknown core";
            }
        }

        // handle custom mirror url templates ({0}/{1} placeholders) or plain directory paths
        private async string update_dat_files (string source) throws GLib.Error {
            string geoip_url = LOYALSOLDIER + "geoip.dat";
            string geosite_url = LOYALSOLDIER + "geosite.dat";
            if (source.contains ("{0}") || source.contains ("{1}")) {
                string placeholder = source.contains ("{0}") ? "{0}" : "{1}";
                geoip_url = source.replace (placeholder, "geoip");
                geosite_url = source.replace (placeholder, "geosite");
            } else if (source.has_suffix ("geoip.dat") || source.has_suffix ("geosite.dat")) {
                geoip_url = source;
                geosite_url = source;
            } else if (source != "") {
                string dir = source.has_suffix ("/") ? source : source + "/";
                geoip_url = dir + "geoip.dat";
                geosite_url = dir + "geosite.dat";
            }
            yield fetch_to (geoip_url, data_file ("geoip.dat"));
            yield fetch_to (geosite_url, data_file ("geosite.dat"));
            return "geoip.dat + geosite.dat updated for xray.";
        }

        // don't download the entire universe: only fetch the rule-sets actually needed by current routing rules
        private async string update_rule_sets (AppSettings settings, Store store) throws GLib.Error {
            var tags = new GLib.HashTable<string, bool> (str_hash, str_equal);
            foreach (var t in ConfigGenerator.rule_set_tags_for (settings, store.get_active_routing_preset ())) {
                tags.insert (t, true);
            }
            if (tags.size () == 0) return "No geosite/geoip tags found in active config. Nothing to download.";

            string source = settings.singbox_ruleset_source.strip ();
            int count = 0;
            foreach (unowned string tag in tags.get_keys ()) {
                foreach (var url in rule_set_urls (source, tag)) {
                    try {
                        yield fetch_to (url, data_file (tag + ".srs"));
                        count++;
                        break;
                    } catch (GLib.Error e) {
                    }
                }
            }
            return "%d srs files updated for sing-box.".printf (count);
        }

        // split sing-box tag into category and code (e.g. "geosite-ru" -> "geosite", "ru")
        private static string[] rule_set_urls (string source, string tag) {
            if (source == "") return {};
            if (!source.contains ("{0}") && !source.contains ("{1}")) return { source };
            bool geosite = tag.has_prefix ("geosite-");
            string category = geosite ? "geosite" : "geoip";
            string code = geosite ? tag.substring (8) : (tag.has_prefix ("geoip-") ? tag.substring (6) : tag);
            string with_category = source.replace ("{0}", category);
            return { with_category.replace ("{1}", tag), with_category.replace ("{1}", code) };
        }

        private static string data_file (string name) {
            return GLib.Path.build_filename (Paths.data_dir (), name);
        }

        private async void fetch_to (string url, string path) throws GLib.Error {
            var bytes = yield HttpClient.fetch (url, false, null, 120);
            GLib.FileUtils.set_contents_full (
                path, (string) bytes.get_data (), (ssize_t) bytes.get_size (),
                GLib.FileSetContentsFlags.CONSISTENT, 0644);
        }
    }
}
