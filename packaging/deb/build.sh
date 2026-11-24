#!/usr/bin/env bash
# Builds the .deb inside the Debian 13 build image (run by build.sh,
# as root). Source: /src (read only use), output: /src/build/packages.
set -euo pipefail

VERSION=${VERSION:?}
ARCH=$(dpkg --print-architecture)
B=/tmp/build-deb
ROOT=/tmp/pkg-root
OUT="${OUT:-/src/build/packages}"
mkdir -p "$OUT"

apt-get update -qq
apt-get install -y -qq --no-install-recommends dpkg-dev >/dev/null

rm -rf "$B" "$ROOT"
meson setup "$B" /src --prefix=/usr --buildtype=release -Dfetch_cores=true
ninja -C "$B"
DESTDIR="$ROOT" meson install -C "$B" --no-rebuild

# Library dependencies from the binary itself (the cores are static).
mkdir -p /tmp/shlibs/debian
printf 'Source: vector-adw\n\nPackage: vector-adw\nArchitecture: any\n' > /tmp/shlibs/debian/control
LIBS=$(cd /tmp/shlibs && dpkg-shlibdeps -O -e "$ROOT/usr/bin/vector-adw" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')

mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/share/doc/vector-adw"
cp /src/LICENSE "$ROOT/usr/share/doc/vector-adw/copyright"
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: vector-adw
Version: $VERSION
Architecture: $ARCH
Maintainer: dp0sk
Section: net
Priority: optional
Homepage: https://github.com/dp0sk/vector
Depends: $LIBS, pkexec, util-linux, systemd
Description: Proxy client for GNOME
 Connects through sing-box, Xray or sing-box-lx (AmneziaWG) as a desktop
 proxy or a system-wide TUN, with subscriptions, routing presets and
 latency and speed tests. The three cores are included.
CONTROL

mkdir -p "$OUT"
DEB="$OUT/vector-adw_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB"
echo "deb: $DEB"
dpkg-deb --field "$DEB" Depends
