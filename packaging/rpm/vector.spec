# Built by build.sh in a Fedora container; the cores are downloaded
# (pinned and checksummed by fetch_cores.py) during %build.
%global debug_package %{nil}

Name:           vector-adw
Version:        0.1.0
Release:        1%{?dist}
Summary:        Proxy client for GNOME
License:        GPL-3.0-only
URL:            https://github.com/dp0sk/vector
Source0:        %{name}-%{version}.tar.gz
ExclusiveArch:  x86_64 aarch64

BuildRequires:  meson
BuildRequires:  ninja-build
BuildRequires:  gcc
BuildRequires:  vala
BuildRequires:  python3
BuildRequires:  desktop-file-utils
BuildRequires:  pkgconfig(gtk4) >= 4.18
BuildRequires:  pkgconfig(libadwaita-1) >= 1.7
BuildRequires:  pkgconfig(libsoup-3.0)
BuildRequires:  pkgconfig(json-glib-1.0)
BuildRequires:  pkgconfig(libqrencode)

Requires:       polkit
Requires:       util-linux
Requires:       systemd

%description
Connects through sing-box, Xray or sing-box-lx (AmneziaWG) as a desktop
proxy or a system-wide TUN, with subscriptions, routing presets and latency
and speed tests. The three cores are included.

%prep
%autosetup

%build
%meson -Dfetch_cores=true
%meson_build

%install
%meson_install

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/io.github.dp0sk.Vector.desktop

%files
%license LICENSE
%doc README.md
%{_bindir}/vector-adw
%{_libexecdir}/vector/
%{_datadir}/applications/io.github.dp0sk.Vector.desktop
%{_datadir}/icons/hicolor/scalable/apps/io.github.dp0sk.Vector.svg
%{_datadir}/icons/hicolor/symbolic/apps/io.github.dp0sk.Vector-symbolic.svg
%{_datadir}/metainfo/io.github.dp0sk.Vector.metainfo.xml
