using Vector.Models;
using Vector.Routing;
using Vector.Subs;
using Vector.Engines;
using Vector.Services;
using Vector.Testing;
using Vector.Ui;
namespace Vector {
    public partial class MainWindow {

        private Gtk.Widget build_service_page () {
            var page = new Adw.PreferencesPage ();
            page.add (build_system_group ());
            page.add (build_tests_group ());
            page.add (build_urls_group ());
            page.add (build_sources_group ());
            return page;
        }

        private Adw.PreferencesGroup build_system_group () {
            service_row = new Adw.ActionRow ();
            service_row.title = "System Service";
            service_uninstall_btn = Widgets.icon_button ("user-trash-symbolic", "Uninstall service");
            service_uninstall_btn.clicked.connect (() => { do_uninstall_service.begin (service_uninstall_btn); });
            service_install_btn = new Gtk.Button.with_label ("Install");
            service_install_btn.valign = Gtk.Align.CENTER;
            service_install_btn.clicked.connect (() => { confirm_install_service (service_install_btn); });
            service_row.add_suffix (service_uninstall_btn);
            service_row.add_suffix (service_install_btn);
            update_service_row ();

            var geo_row = new Adw.ActionRow ();
            geo_row.title = "Geo Data";
            var geo_btn = new Gtk.Button.with_label ("Update");
            geo_btn.valign = Gtk.Align.CENTER;
            geo_btn.clicked.connect (() => { do_update_geo.begin (geo_btn); });
            geo_row.add_suffix (geo_btn);

            var geo_interval_row = spin_setting_row ("Auto-update Every (h)", 0, 168, settings.geo_update_interval,
                                                     (v) => { settings.geo_update_interval = v; });
            geo_interval_row.subtitle = "0 = off";

            var group = new Adw.PreferencesGroup ();
            group.title = "System";
            group.add (service_row);
            group.add (geo_row);
            group.add (geo_interval_row);
            return group;
        }

        private Adw.PreferencesGroup build_tests_group () {
            var show_all_row = new Adw.SwitchRow ();
            show_all_row.title = "Show \"All\" Tab";
            show_all_row.subtitle = "Tests there cover every server";
            Widgets.bind_switch (show_all_row, settings, "show_all_tab");
            settings.notify["show-all-tab"].connect (() => rebuild_server_tabs ());

            var group = new Adw.PreferencesGroup ();
            group.title = "Tests";
            group.add (spin_setting_row ("Parallel Tests", 1, 50, settings.concurrent_tests,
                                         (v) => { settings.concurrent_tests = v; }));
            group.add (spin_setting_row ("Timeout (s)", 1, 60, settings.test_timeout,
                                         (v) => { settings.test_timeout = v; }));
            group.add (show_all_row);
            return group;
        }

        private Adw.PreferencesGroup build_urls_group () {
            var group = new Adw.PreferencesGroup ();
            group.title = "URLs";
            group.add (url_setting_row ("Ping URL", settings.ping_url, {
                PresetEntryRow.PresetItem ("", "https://www.google.com/generate_204"),
                PresetEntryRow.PresetItem ("", "https://www.youtube.com/generate_204"),
                PresetEntryRow.PresetItem ("", "https://www.googlevideo.com/generate_204"),
                PresetEntryRow.PresetItem ("", "https://www.gstatic.com/generate_204"),
                PresetEntryRow.PresetItem ("", "https://www.apple.com/library/test/success.html"),
                PresetEntryRow.PresetItem ("", "http://www.msftconnecttest.com/connecttest.txt")
            }, (v) => { settings.ping_url = v; }));
            group.add (url_setting_row ("Speed Test URL", settings.speed_url, {
                PresetEntryRow.PresetItem ("", "https://speed.cloudflare.com/__down?bytes=10000000"),
                PresetEntryRow.PresetItem ("", "https://speed.cloudflare.com/__down?bytes=50000000"),
                PresetEntryRow.PresetItem ("", "https://speed.cloudflare.com/__down?bytes=99999999"),
                PresetEntryRow.PresetItem ("", "https://cachefly.cachefly.net/10mb.test"),
                PresetEntryRow.PresetItem ("", "https://cachefly.cachefly.net/50mb.test"),
                PresetEntryRow.PresetItem ("", "https://cachefly.cachefly.net/100mb.test")
            }, (v) => { settings.speed_url = v; }));
            group.add (url_setting_row ("IP Check URL", settings.connection_info_test_url, {
                PresetEntryRow.PresetItem ("", "https://api.ipify.org?format=text"),
                PresetEntryRow.PresetItem ("", "https://api.ipify.org?format=json"),
                PresetEntryRow.PresetItem ("", "https://ifconfig.me/ip"),
                PresetEntryRow.PresetItem ("", "https://api.ip.sb/geoip"),
                PresetEntryRow.PresetItem ("", "https://api-ipv4.ip.sb/geoip"),
                PresetEntryRow.PresetItem ("", "https://api-ipv6.ip.sb/geoip"),
                PresetEntryRow.PresetItem ("", "https://api.ipapi.is")
            }, (v) => { settings.connection_info_test_url = v; }));
            group.add (url_setting_row ("Subscription Converter", settings.sub_converter_url, {
                PresetEntryRow.PresetItem ("", "https://sub.xeton.dev/sub?url={0}"),
                PresetEntryRow.PresetItem ("", "https://api.dler.io/sub?url={0}"),
                PresetEntryRow.PresetItem ("", "http://127.0.0.1:25500/sub?url={0}")
            }, (v) => { settings.sub_converter_url = v; }));
            return group;
        }

        private Adw.PreferencesGroup build_sources_group () {
            var group = new Adw.PreferencesGroup ();
            group.title = "Sources";
            group.description = "Optional";
            group.add (url_setting_row ("Geo Files", settings.geo_files_source, {
                PresetEntryRow.PresetItem ("Global Preset", "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/{0}.dat"),
                PresetEntryRow.PresetItem ("Russia Preset", "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/{0}.dat"),
                PresetEntryRow.PresetItem ("Iran Preset", "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/{0}.dat"),
                PresetEntryRow.PresetItem ("China Preset", "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/{0}.dat")
            }, (v) => { settings.geo_files_source = v; }));
            group.add (url_setting_row ("sing-box Rule Sets", settings.singbox_ruleset_source, {
                PresetEntryRow.PresetItem ("Global Preset", "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-{0}/{1}.srs"),
                PresetEntryRow.PresetItem ("Russia Preset", "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-{0}/{1}.srs"),
                PresetEntryRow.PresetItem ("Iran Preset", "https://raw.githubusercontent.com/chocolate4u/Iran-sing-box-rules/rule-set/{1}.srs"),
                PresetEntryRow.PresetItem ("China Preset", "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-{0}/{1}.srs")
            }, (v) => { settings.singbox_ruleset_source = v; }));
            group.add (url_setting_row ("Routing Presets", settings.routing_rules_source, {
                PresetEntryRow.PresetItem ("Global Preset", "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-custom-routing-list/refs/heads/main/v2rayN/all.json"),
                PresetEntryRow.PresetItem ("Russia Preset", "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-custom-routing-list/main/v2rayN/template.json"),
                PresetEntryRow.PresetItem ("Iran Preset", "https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/main/v2rayN/template.json"),
                PresetEntryRow.PresetItem ("China Preset", "https://raw.githubusercontent.com/2dust/v2rayCustomRoutingList/master/custom_routing_rules_whitelist")
            }, (v) => { settings.routing_rules_source = v; }));
            return group;
        }

        private Adw.SpinRow spin_setting_row (string title, int min, int max, int value, owned IntSetting store_value) {
            var row = new Adw.SpinRow.with_range (min, max, 1);
            row.title = title;
            row.value = value;
            row.notify["value"].connect (() => {
                store_value ((int) row.value);
                settings.save ();
            });
            return row;
        }

        private PresetEntryRow url_setting_row (string title, string value, PresetEntryRow.PresetItem[] presets,
                                                owned StringSetting store_value) {
            var row = new PresetEntryRow (title, value, presets);
            row.changed.connect (() => {
                store_value (row.text);
                settings.save ();
            });
            return row;
        }

        private Adw.ActionRow? service_row = null;
        private Gtk.Button service_install_btn;
        private Gtk.Button service_uninstall_btn;

        private void update_service_row () {
            if (service_row == null) return;
            bool present = SystemdInstaller.service_present ();
            if (SystemdInstaller.router_installed ()) {
                service_row.subtitle = "Installed: TUN without a password";
            } else if (present) {
                service_row.subtitle = "Outdated: reinstall to use TUN";
            } else {
                service_row.subtitle = "Optional: TUN without a password";
            }
            service_install_btn.label = present ? "Reinstall" : "Install";
            service_uninstall_btn.visible = present;
        }

        // warn user if TUN is currently up: reinstalling bounces the service and cuts active traffic
        private void confirm_install_service (Gtk.Button btn) {
            if (!(runner.running && runner.tun_mode)) {
                do_install_service.begin (btn);
                return;
            }
            var dialog = new Adw.AlertDialog ("Reinstall the TUN service?",
                "The running TUN connection will stop during installation. Press Start again afterwards.");
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("install", "Reinstall");
            dialog.set_response_appearance ("install", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            dialog.response.connect ((d, resp) => {
                if (resp == "install") do_install_service.begin (btn);
            });
            dialog.present (this);
        }

        private async void do_install_service (Gtk.Button btn) {
            btn.sensitive = false;
            yield install_tun_service ();
            btn.sensitive = true;
        }

        // install systemd unit via pkexec. if TUN is running right now, stop it first so the service takes over clean
        private async bool install_tun_service () {
            bool ok = true;
            try {
                yield installer.install (settings.tun_router_core);
                show_toast ("Service installed. TUN start/stop is now password-less.");
                append_log ("[app] TUN router (API %d) + polkit rule installed.".printf (SystemdInstaller.ROUTER_API));
                if (runner.running && runner.tun_mode) yield runner.stop_async ();
                if (yield runner.session.is_alive ()) yield runner.session.stop ();
            } catch (GLib.Error e) {
                show_toast ("Service install failed: %s".printf (e.message));
                append_log ("[app] service install failed: %s".printf (e.message));
                ok = false;
            }
            update_service_row ();
            return ok;
        }

        private async void do_uninstall_service (Gtk.Button btn) {
            btn.sensitive = false;
            try {
                yield installer.uninstall ();
                if (runner.router_kind == RouterKind.SERVICE) runner.stop ();
                show_toast ("Service cleanly uninstalled.");
                append_log ("[app] systemd unit + polkit rule + SELinux policies uninstalled.");
            } catch (GLib.Error e) {
                show_toast ("Service uninstall failed: %s".printf (e.message));
                append_log ("[app] service uninstall failed: %s".printf (e.message));
            }
            update_service_row ();
            btn.sensitive = true;
        }

        private async void do_update_geo (Gtk.Button btn) {
            btn.sensitive = false;
            append_log ("[app] updating geo assets for %s...".printf (routing_core ()));
            try {
                string msg = yield geo_mgr.update (routing_core (), settings, store);
                settings.geo_last_update = GLib.get_real_time () / 1000000;
                settings.save ();
                show_toast (msg);
                append_log ("[app] " + msg);
            } catch (GLib.Error e) {
                show_toast ("Geo update failed: %s".printf (e.message));
                append_log ("[app] geo update failed: %s".printf (e.message));
            }
            btn.sensitive = true;
        }
    }
}
