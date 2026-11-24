# SLOPMACHINE.md — Vector Developer & Agent Guidelines

## 1. Project Overview & Mission

**Vector** is a modern, native Linux desktop client for proxy engines (**sing-box**, **Xray-core** and **sing-box-lx**, a sing-box fork with AmneziaWG), designed following the GNOME Human Interface Guidelines (HIG) with **GTK4** and **Libadwaita**. It is implemented in **Vala** and compiles to native C code via Meson and Ninja.

### Primary Capabilities
- **Multi-Protocol Support**: VLESS (incl. Reality), VMess, Trojan, Shadowsocks, SOCKS and HTTP over TCP, WebSocket, gRPC, HTTPUpgrade, XHTTP and HTTP/2 transports; WireGuard and AmneziaWG (awg-quick `.conf` import with multi-peer support, AmneziaVPN `vpn://` links); Hysteria 2 and TUIC over sing-box. Share links import/export (`vless://`, `vmess://`, `trojan://`, `ss://`, `socks://`, `http(s)://`, `hysteria2://`, `tuic://`).
- **Three Cores, chosen per protocol**: `sing-box`, `xray` and `sing-box-lx` (Core page → Core per Protocol, `Cores`). XHTTP runs only on xray, AmneziaWG only on sing-box-lx.
- **Routing & Rule Engine**: Outbound routing presets (Direct, Proxy, Block), customizable domains/IP rules, GeoIP/GeoSite database integration.
- **System Proxy & TUN Mode**: Desktop proxy via GSettings (`org.gnome.system.proxy`, plus kioslaverc on KDE). Every mode is a sing-box router in front of an unprivileged engine; TUN runs either from the installed `vector-tun.service` or, without installing anything, for one login session after one password prompt (see §4.5).
- **Benchmarking & Latency**: Real-time HTTP/TCP ping, download throughput benchmarking, and live dynamic list sorting.
- **Subscription Management**: Auto-updating subscription groups, Base64/SIP002 decoding, QR code display/scanning.
- **Adaptive UI**: Responsive layout using `AdwOverlaySplitView`, mobile/narrow form factor adaptability, dark mode, custom CSS styling, and system tray (StatusNotifierItem/AppIndicator).

---

## 2. Tech Stack & Environment

| Component | Technology | Minimum Version / Details |
|---|---|---|
| **Language** | Vala + C | `valac >= 0.56` (`--target-glib=2.74`) |
| **Build System** | Meson + Ninja | `meson >= 0.62`, `ninja` |
| **GUI Framework** | GTK4 + Libadwaita | `gtk4 >= 4.18`, `libadwaita-1 >= 1.7` (the AppImage build base, Debian 13) |
| **Networking & JSON** | libsoup-3.0, json-glib-1.0 | Asynchronous HTTP and JSON serialization |
| **QR codes** | libqrencode | Drawn in memory (`QrCode.texture`); binding in `src/vapi/libqrencode.vapi` |
| **System Libraries** | GLib / GObject / GIO | `>= 2.74`, Posix Vala bindings |
| **Proxy Cores** | sing-box, Xray-core, sing-box-lx | Bundled or fetched to libexec (`fetch_cores.py`: pinned versions, SHA-256 checked) |
| **Packaging** | AppImage, deb, rpm | `build.sh --appimage/--deb/--rpm` (portable, Debian 13 container) |
| **OS Requirements** | Linux | GNOME/Wayland/X11, Polkit for TUN root operations |

---

## 3. Architecture & Codebase Map

```
vector/
├── meson.build                  # Meson build definitions and dependency checks
├── meson_options.txt            # Build options (fetch_cores)
├── fetch_cores.py               # Downloads the pinned, sha256-checked xray, sing-box and sing-box-lx
├── build.sh                     # Unified build script: --bin --appimage --deb --rpm --all
├── packaging/                   # Containerfile.appimage, deb/build.sh, rpm/vector.spec
├── TODO.md                      # Known gaps, unverified items and backlog
├── data/                        # Desktop file, metainfo, SVG icon, style.css, GResource manifest
└── src/                         # namespace Vector (shell) + sub-namespaces per domain folder
    ├── Application.vala         # Entry point, Adw.Application (main() inside the class)
    ├── config.vala.in           # Template configuring Vector.Config constants (libexec path, version, pinned core versions)
    ├── Window.vala              # MainWindow (partial class): fields, lifecycle, layout, helpers
    ├── vapi/                    # Hand-written Vala bindings (libqrencode)
    ├── window/                  # More MainWindow parts that are not pages (namespace Vector)
    │   ├── ConnectFlow.vala     # Connect / disconnect: router + engine, TUN switch, core switch
    │   ├── ConnectionStatus.vala# Active node, IP / latency / country check, Start button state
    │   └── SystemProxyTray.vala # Desktop proxy mode and the tray menu
    │
    ├── models/                  # namespace Vector.Models — data structures and settings persistence
    │   ├── Node.vala            # Proxy server model (URI/Happ/JSON-config parsing, latency, share export)
    │   ├── WgConfig.vala        # WireGuard peer config model
    │   ├── AppSettings.vala     # App configuration (~/.config/vector/settings.json)
    │   └── Store.vala           # Stores nodes, groups, and serialization
    │
    ├── routing/                 # namespace Vector.Routing — routing rules and presets
    │   ├── RoutingRule.vala     # Domain/IP routing rules definition
    │   ├── RoutingPreset.vala   # Preset routing profiles (Bypass CN/LAN, etc.)
    │   └── RoutingRulesFetcher.vala # Remote routing presets download & parsing
    │
    ├── subscriptions/           # namespace Vector.Subs — subscription import pipeline
    │   ├── SubGroup.vala        # Subscription group data model
    │   ├── SubscriptionManager.vala # Subscription download, base64 decoding, parsing (incl. Happ format)
    │   └── HappLink.vala        # happ://crypt deep-link decryption (crypt1-crypt5, RSA + ChaCha20-Poly1305)
    │
    ├── engines/                 # namespace Vector.Engines — the three cores and their configs
    │   ├── Cores.vala           # The three cores and which protocol each can serve
    │   ├── CoreRunner.vala      # Router (service / session / user unit) + engine lifecycle, log tailing
    │   ├── UserUnit.vala        # A core as a transient systemd --user unit (engine, proxy-mode router)
    │   ├── SessionRouter.vala   # TUN router for one login session (pkexec + setpriv, no install)
    │   ├── SystemdInstaller.vala# One-time privileged install of the TUN router
    │   └── config/              # ConfigGenerator (partial class)
    │       ├── ConfigGenerator.vala # Entry points, shared JSON helpers, rule-set tags
    │       ├── JsonSink.vala        # Fluent JSON builder used by config generators
    │       ├── SingBoxConfig.vala   # Router, engine, test, export configs for sing-box(-lx)
    │       └── XrayConfig.vala      # Engine, test, export configs for xray (incl. embedded provider configs)
    │
    ├── services/                # namespace Vector.Services — platform integration and helpers
    │   ├── Paths.vala           # Centralized filesystem paths resolution
    │   ├── Util.vala            # String helpers, URL masking, write_private(), misc utilities
    │   ├── SystemProxy.vala     # Desktop proxy (GSettings, KDE kioslaverc)
    │   ├── HttpClient.vala      # Shared HTTP client for all downloads
    │   ├── LogFormatter.vala    # Normalizes and de-noises core log lines
    │   ├── GeoManager.vala      # GeoIP/GeoSite database download & update
    │   └── TrayIcon.vala        # System tray / StatusNotifierItem integration
    │
    ├── testing/                 # namespace Vector.Testing — latency and speed measurement
    │   ├── Tester.vala          # Latency / TCP ping testing engine, IP/country check
    │   └── Benchmarker.vala     # Concurrency-controlled speed & ping test
    │
    ├── pages/                   # MainWindow partial classes for views (namespace Vector)
    │   ├── servers/             # Servers page
    │   │   ├── ServersPage.vala     # Page layout, group tabs, selection
    │   │   ├── ServersNodes.vala    # Add / import / remove / share nodes, node context menu
    │   │   ├── ServersTests.vala    # Real delay and speed tests
    │   │   └── ServersSorting.vala  # Column sorting, compact sort bar, live re-sort
    │   ├── SubsPage.vala        # Subscription groups UI, QR, & manual update
    │   ├── RoutePage.vala       # Routing presets, domain strategy, bypass rules
    │   ├── CorePage.vala        # Core engine selection, ports, background mode
    │   ├── ServicePage.vala     # TUN service installer, Geo assets, test URLs
    │   └── LogPage.vala         # Real-time stdout/stderr log viewer
    │
    └── ui/                      # namespace Vector.Ui — reusable UI widgets and dialogs
        ├── NodeRow.vala         # Custom server row widget
        ├── MatchWidthBin.vala   # Caps a widget at a multiple of another one's width (START button)
        ├── PresetEntryRow.vala  # Routing preset row widget
        ├── NodeEditDialog.vala  # Server editor (form, .conf text for WireGuard/AmneziaWG, JSON for xray-json)
        ├── GroupEditDialog.vala # Subscription group editor
        ├── RoutingDialog.vala   # Routing preset and rule editor
        ├── DialogHeader.vala    # The one editor header: Cancel | title | Save/Done
        ├── QrCode.vala          # QR code texture renderer (libqrencode wrapper)
        ├── Clipboard.vala       # Clipboard read/write helpers
        └── Widgets.vala         # Small builders: icon buttons, delete confirmation, Callback
```

---

## 4. Key Architectural Patterns & Invariants

### 4.1 The Partial Class Pattern for MainWindow
- `MainWindow` is declared as `public partial class MainWindow : Adw.ApplicationWindow`.
- Fields, constructor, window lifecycle, layout and shared UI helpers live in `src/Window.vala`; connect flow, connection status and tray in `src/window/`.
- Pages live in `src/pages/`: `servers/` (four files), `SubsPage.vala`, `RoutePage.vala`, `CorePage.vala`, `ServicePage.vala` and `LogPage.vala`.
- Each part declares the fields it uses itself; a page is built from small `build_*_group` / `build_*` functions, one per visible section.
- **COMPILATION ORDER**: `meson.build` lists `src/Window.vala` (which names the base class) before `src/window/` and `src/pages/`. `ConfigGenerator` is a partial class too: only `engines/config/ConfigGenerator.vala` names its base class.
- **NAMESPACES**: the window shell stays in the root `namespace Vector`; every domain folder carries its own sub-namespace (`Vector.Models`, `Vector.Routing`, `Vector.Subs`, `Vector.Engines`, `Vector.Services`, `Vector.Testing`, `Vector.Ui`). Cross-namespace types are reached with `using` directives at the top of the file; where a name collides with GLib (`Node`, `Callback`), qualify it (`Models.Node`, `Ui.Callback`).

### 4.2 Prevent UI Feedback Loops (`updating_ui` Guard)
- Simple settings rows must NOT hand-wire the `settings.X = row.X; settings.save()` loop: bind them with `Widgets.bind_switch (row, settings, "prop")` (or `Widgets.bind_setting (row, "prop", settings, "prop")` for non-boolean widget properties). The bidirectional `GLib.Binding` renders the stored value and writes edits back; side effects react to `settings.notify[prop]`, so programmatic changes stay loop-free without any flag.
- The `updating_ui` boolean field remains ONLY for bulk programmatic UI updates that have no settings backing (e.g., `restore_active_node_state()` or `on_state_changed()`): set it to `true` beforehand and reset to `false` afterwards, and signal handlers for widget toggles/changes must check `if (updating_ui) return;` to avoid cyclic triggers and unnecessary config re-saves.

### 4.3 Thread Safety & Asynchronous Operations
- Vala's `async` methods (`public async void ...`) and `yield` operators run cooperatively on the GLib main context (`GMainContext`).
- **Never invoke GTK widget modifications from secondary threads**. If worker threads or external callbacks are used, marshal back to the UI thread using `GLib.Idle.add(() => { ... return false; });`.
- Subprocesses (e.g., `CoreRunner`, `Tester`, `SubscriptionManager`) must use asynchronous I/O (`GLib.Subprocess`, `GLib.DataInputStream.read_line_async`) to keep the UI smooth and 60 FPS responsive.

### 4.4 Dynamic Sorting Invariance
- `src/pages/servers/ServersSorting.vala` supports live dynamic sorting by latency or speed while benchmarks run.
- When dynamic sorting triggers (`schedule_dynamic_sort()`), preserve selection and scroll positions so rows do not jump under the user's cursor.

### 4.5 Router + Engine in Every Mode
Every connection is a **router** (sing-box: DNS, all routing rules, the local mixed port the desktop proxy points to, plus the TUN in TUN mode) in front of an unprivileged **engine** that serves one node on `127.0.0.1:engine_port`. Rules come from one generator (`ConfigGenerator.gen_router`, node-independent) in all modes.

The **engine** is sing-box, xray or sing-box-lx (chosen by `Cores.engine_core_for`), written to `engine.json`, run as the `systemd-run --user` unit `vector-engine.service` (`UserUnit`). Switching node or core replaces only the engine.

**Router kinds** (`RouterKind`, `CoreRunner`); exactly one runs at a time, and switching TUN on/off replaces only the router (the engine stays):

- `SERVICE` — `vector-tun.service`, installed once by `SystemdInstaller` (one `pkexec` prompt): `vector-router` (a pinned sing-box copy in `/usr/local/libexec/vector/`), the unit (router as the user with `CAP_NET_ADMIN`, `ExecReload` = SIGHUP) and a polkit rule for password-less start/stop/reload. Config: `router.json`.
- `SESSION` — TUN without installing (`SessionRouter`): `systemd-run --user --scope` → `sh -c 'pkexec "$@"; exit $?'` → `pkexec setpriv --reuid=<user> --ambient-caps=+net_admin,+net_raw,+net_bind_service --pdeathsig=TERM` → the user's stable sing-box with `router.json`. One password prompt per login session; the router runs as the user, so the app reloads (SIGHUP) and stops it without root. TUN off reloads it with an idle config (no inbounds) instead of stopping it, so TUN returns without a new prompt. pkexec's PAM session (`pam_systemd`, Fedora 45) moves the router out of the scope, so it is tracked by PID (`$XDG_RUNTIME_DIR/vector/session-router-pid`), and the `sh` stays in the scope as its parent: at logout systemd ends the scope and the router dies with its parent (pdeathsig). Log: `session-router.log`.
- `USER` — proxy mode: the `vector-proxy.service` user unit with `proxy-router.json` (no TUN).

Additional invariants:
- When TUN is turned on without the service, a dialog offers "Start for This Session" (primary) or "Install as System Service". If the new router fails (e.g. password cancelled), the previous router is restored.
- Route rule 0 (TUN routers only) sends processes named `sing-box`/`xray`/`sing-box-lx` direct (`ENGINE_PROCESS_NAMES`), so engines and latency testers never loop through the TUN. Engines resolve server addresses with their own direct DNS.
- The router core is pluggable: `ROUTER_API` / `ROUTER_CORE` files in `/usr/local/libexec/vector/` version the privileged part and name the router core (`SystemdInstaller.ROUTER_CORES`). Never hardcode `"sing-box"` for routing decisions.
- **Never restart the live `vector-tun.service` while developing**: test TUN changes in an isolated container network namespace, and run test instances with `VECTOR_UNIT_SUFFIX` (see §6 Testing).

### 4.6 File Paths & Persistence
- Do **not** hardcode paths (`~/.config/...`). Always route through `src/services/Paths.vala`.
- Configurations (`~/.config/vector/`, dir 0700, files 0600 — they contain credentials):
  - `settings.json`, `nodes.json`, `subs.json` (groups), `routing.json` (presets)
  - Generated: `router.json` (TUN routers), `proxy-router.json` (proxy-mode router), `engine.json` (engine)
- Data (`~/.local/share/vector/`): geo files / `.srs` rule-sets, `router.log` (service), `proxy-router.log`, `session-router.log`, `engine.log`, `bin/` (core binaries copied from the bundle; long-running cores never run from the AppImage mount).
- Temporary test configs: `$XDG_RUNTIME_DIR/vector/` (`Paths.runtime_dir`).

---

## 5. Build Commands

```bash
meson setup build                  # first time (-Dfetch_cores=false to skip downloading cores)
ninja -C build                     # build; this is the only automated check
./build/vector-adw                 # run
G_MESSAGES_DEBUG=all ./build/vector-adw

meson setup --reconfigure build    # if meson.build or options changed
meson setup -Dappimage=true build  # to enable the appimage ninja target
```

The generated C is built with `-w` (valac's C is noisy by design). To check it for real GCC warnings, configure a second build dir with `-Dgcc_warnings=true`: it hides only the kinds valac always produces. The 64 `-Wincompatible-pointer-types` warnings stay, because valac re-enables them with `#pragma`.

New `.vala` files must be added by hand to the source list in `meson.build`. MainWindow parts (`src/window/`, `src/pages/`) must come after `src/Window.vala`.

### Packaging

```bash
./build.sh --appimage              # portable AppImage in a Debian 13 container → build/packages/
./build.sh --appimage --no-container  # from ./build on the host

./build.sh --deb                   # .deb, Debian 13 container
FEDORA_RELEASE=44 ./build.sh --rpm # .rpm, that Fedora release
./build.sh --all                   # bin + AppImage + deb + rpm
```

```bash
python3 fetch_cores.py build  # download the pinned cores manually into build/
```

---

## 6. Testing

The logic layer (parsers, crypto, config generation) has a GTK-free test suite: `meson test -C build` (the `logic` test in `tests/LogicTests.vala`). If a change touches parsing or config generation, add a case there.

**Never touch the live setup.** The developer's own traffic goes through the running `vector-tun.service` and `vector-engine.service`. Do not restart them, and never trigger a real `pkexec` or polkit prompt from a test.

**Isolated app instances:** run `./build/vector-adw` on Xvfb with its own `HOME`/`XDG_*_HOME`, `GSETTINGS_BACKEND=memory` and `VECTOR_UNIT_SUFFIX=test`.
- The suffix renames every unit (`vector-engine-test.service`, `vector-proxy-test.service`, …) and makes the instance treat the system service as not installed, so it never calls systemd on the system bus for it. It also runs as a non-unique GApplication, so it does not hand over to the developer's running app.
- Put a fake `pkexec` first in `PATH` to exercise the session-router path.
- `VECTOR_LOG_STDOUT=1` prints the in-app log to stdout.
- Pass the variables with a bash script or `env VAR=… VAR=…`. In zsh, `env $VARS` does not word-split and the instance ends up on the real display with real unit names.

**TUN and the session router:** reproduce in a rootless privileged podman container with its own netns. Put a remote side (server, target, DNS) in a second network namespace reachable only via the default route, because sing-box `auto_route` skips connected subnets. Rootless podman cannot `ip netns add` (it fails to mount `/sys`): start `unshare --net sleep infinity &`, move a veth end into that PID and run the remote side with `nsenter -t <pid> -n`. For the session router, run the `setpriv` chain as root in the container (that is what `pkexec` would run).

**Config generator changes:** dump every generated config (routers with and without TUN, engines, testers, exports) for a fixed set of nodes and presets before and after the change and diff them; a refactor must give byte-identical output.

**AmneziaWG:** a second sing-box-lx with a `wireguard` endpoint (`listen_port`, same AWG keys) is a working AWG server. Its netstack drops packets to 127.0.0.1, so use a non-loopback target address.

Latency tests and benchmarks (`src/pages/servers/ServersTests.vala`, `Benchmarker`) start throwaway cores on separate ports using `ConfigGenerator.gen_test_for`.

Core binary lookup (`Paths.find_core`) tries these locations in order:
1. next to the executable
2. `../libexec/vector`
3. `$APPDIR/usr/libexec/vector`
4. `~/.local/share/vector/bin`
5. the baked-in `Build.LIBEXECDIR`
6. `/usr{,/local}/libexec/vector`
7. `$PATH`

---

## 7. Coding Conventions & Best Practices

### 7.1 Vala Language Idioms
- **Indentation**: 4 spaces, no tabs.
- **Naming**:
  - Types / Classes / Structs / Enums: `PascalCase` (`MainWindow`, `AppSettings`, `RoutingRule`)
  - Methods and properties: `snake_case` (`build_ui`, `get_active_node`, `save_settings`)
  - Signals: `snake_case` (`log_line`, `state_changed`)
  - Constants: `UPPER_SNAKE_CASE` (`DEFAULT_PORT`, `SCHEMA_ID`)
- **Nested `?:` with strings**: do not nest a ternary that mixes string literals with an owned string (`n == 0 ? "a" : (n == 1 ? "b" : "%u".printf (n))`). valac 0.56.18 (Debian 13, the AppImage build) compiles it to a freed pointer; newer valac does not, so it only breaks in the AppImage. Use `if`/`else`.
- **Memory Management & ARC**:
  - Vala uses automatic reference counting for `GLib.Object`.
  - Avoid circular references in lambda connections (`connect (...)`). If a signal handler captures `this` and the signal source is owned by `this`, disconnect signals upon destruction or use `[Weak]` references when necessary.

### 7.2 Error Handling
- Use Vala `throws GLib.Error` for recoverable operations (file I/O, network requests, JSON parsing).
- Always catch specific errors and provide descriptive logs (`append_log`) and user-facing notifications via `show_toast()`.

```vala
try {
    store.save_nodes ();
} catch (GLib.Error e) {
    append_log ("[store] Failed to save nodes: %s".printf (e.message));
    show_toast ("Error saving nodes");
}
```

### 7.3 UI & CSS Guidelines
- Custom CSS lives in `data/style.css`, compiled into the binary via `data/io.github.dp0sk.Vector.gresource.xml` (resource base path `/io/github/dp0sk/Vector`). `Adw.Application` loads `style.css` from there and GTK adds `icons/` to the icon theme, so no code loads either. New resource files go into that XML.
- Do not introduce inline ad-hoc styles in widgets if possible; prefer adding semantic CSS classes (`.editor-card`, `.numeric`, `.server-col-btn`) and declaring them in `data/style.css`.
- Use Libadwaita color variables (`@accent_bg_color`, `@card_bg_color`, `@window_bg_color`, `@view_hover_bg_color`) to ensure seamless support for light and dark system themes.

---

## 8. Git & Commit Guidelines

This project follows the **Conventional Commits** specification:

```text
<type>(<scope>): <short imperative description>
```

Common types & scopes:
- `feat(ui)`: New UI features, adaptive layouts, widgets
- `fix(ui)`: UI bugfixes, layout corrections, styling fixes
- `feat(core)`: Support for new proxy protocols or engine features
- `fix(sysproxy)`: System proxy routing or GSettings adjustments
- `refactor(services)`: Code cleanup, performance optimization without behavior changes
- `build`: Meson, packaging, dependencies, or AppImage script updates

Rules:
- Verify compilation before committing: `ninja -C build`.
- Keep commit messages concise, in imperative mood ("add", "fix", "restore", not "added" or "fixing").
- Never leave untracked debug artifacts, temporary logs, or scratch files in git status.

