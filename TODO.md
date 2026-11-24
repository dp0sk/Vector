# TODO & Backlog

Overview of current limitations, items pending real-world validation, and architectural backlog.

---

## 1. Pending Real-Hardware Verification

- [ ] **IPv6 over TUN**: IPv6 routing is only active when set to "IPv6 → Prefer IPv6" (using ULA `fdfe:dcba:9876::1/126`). Tested in network namespaces and containers, but pending verification on an ISP with native public IPv6. In other modes, `strict_route` rejects IPv6 immediately so clients cleanly fall back to IPv4.
- [ ] **KDE System Proxy Integration**: Desktop proxy configuration for KDE Plasma via `kwriteconfig` → `kioslaverc` (`ProxyType=1`, `httpProxy`, `socksProxy`, `NoProxyFor`) needs interactive validation in a live KDE session (GNOME via dconf/GSettings is fully verified).

---

## 2. Known Limitations & Edge Cases

- [ ] **Hot Routing Reload (SIGHUP)**: Clicking "Reconnect" in the toast after modifying routing rules sends SIGHUP to the sing-box router. sing-box restarts its core engine upon SIGHUP, which terminates existing TCP connections (e.g., active file downloads fail; ping and new connections resume immediately). sing-box does not support live rule updates without a core reload.
- [ ] **xray 26.x and Insecure TLS**: xray 26.x removed `allowInsecure: true` in favor of `pinnedPeerCertSha256`. Consequently, Vector does not pass `allow_insecure` into xray configs, enforcing strict TLS certificate checks on xray. Self-signed TLS nodes only connect using sing-box / sing-box-lx. (Optional future enhancement: add a `pinnedPeerCertSha256` input field in `NodeEditDialog`).
- [ ] **Amnezia `vpn://` Share Links**: `Node.amnezia_link_to_conf()` only extracts WireGuard and AmneziaWG containers. Other protocols (OpenVPN, Cloak) are not supported because Vector does not bundle or integrate OpenVPN/Cloak engines (only sing-box, xray, and sing-box-lx).
- [ ] **Pinned Core Binaries**: Binary versions of xray, sing-box, and sing-box-lx alongside their SHA-256 hashes are hard-pinned in `fetch_cores.py` and must be bumped manually.

---

## 3. Architectural Backlog

- [ ] **Proxy Chaining / Relay (Multi-hop)**: Allow routing traffic through a chain of proxy servers (Entry Node → Exit Node / Relay):
  - In `sing-box`: Natively supported by configuring multiple outbounds and setting `"detour": "proxy-entry"` on the exit outbound.
  - In `xray`: Supported via `proxySettings: { "tag": "proxy-entry" }` on the outbound.
  - Requires UI addition in `NodeEditDialog` or the server list (e.g., "Detour / Tunnel via" selector) and generator adjustments in `ConfigGenerator.gen_engine_for`. The router remains untouched (transparently forwards to engine port 10808).
- [ ] **Flatpak Sandbox via Client-Daemon Model**:
  - *Context*: Vector currently operates as a unified host process that writes configs to `~/.config/vector/`, starts user units via `systemd-run --user`, and interacts with host `dconf`. Running inside Flatpak with full host access (`flatpak-spawn --host`) violates Flathub security guidelines.
  - *Target Architecture*: Transition to a decoupled **Client-Daemon** architecture (similar to Mullvad, Tailscale, and CoreCtrl):
    1. **Host Daemon (`vector-daemon`)**: A background service on the host that owns the `vector0` TUN device, network capabilities (`CAP_NET_ADMIN`), and system proxy interactions.
    2. **Sandboxed Flatpak Client (`vector-adw`)**: The GUI runs inside the standard Flatpak sandbox without escape permissions. It communicates with the host daemon exclusively via a dedicated D-Bus interface on the System Bus (`--system-talk-name=io.github.dp0sk.Vector.Daemon`) or a restricted Unix domain socket (`/run/vector/control.sock`).
    3. *Required Refactoring*: Extract core-lifecycle, systemd unit management, and config generation out of the GUI layer into the daemon IPC boundary.
- [ ] **Secondary Router Core (Xray Router)**: Extensibility points are ready (`ROUTER_CORES`, `gen_router_for`, `router_exec_args`), but requires manual translation of routing rules and DNS routing for xray router mode.

---

## 4. Distribution & Hardening Notes

- [ ] **SELinux Integration**: Specific policy modules were removed in favor of running standard `restorecon`. Tested on Fedora 45 (Enforcing & Permissive) with zero AVC denials under user session and TUN modes. On strict enterprise distributions (RHEL/CentOS), inspect AVC denials via `ausearch -m avc -ts today` if issues arise.
