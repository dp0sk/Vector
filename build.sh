#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(grep -oP "version:\s*'\K[^']+" "$PROJECT_DIR/meson.build" | head -1)"
BUILD_ROOT="$PROJECT_DIR/build"
OUT="$BUILD_ROOT/packages"
IMAGE="vector-appimage-builder"
FEDORA_RELEASE="${FEDORA_RELEASE:-44}"

DO_BIN=0
DO_APPIMAGE=0
DO_DEB=0
DO_RPM=0
NO_CONTAINER=0
CONTAINER_SETUP=0

for arg in "$@"; do
    case "$arg" in
        --bin)             DO_BIN=1 ;;
        --appimage)        DO_APPIMAGE=1 ;;
        --deb)             DO_DEB=1 ;;
        --rpm)             DO_RPM=1 ;;
        --all)             DO_BIN=1; DO_APPIMAGE=1; DO_DEB=1; DO_RPM=1 ;;
        --no-container)    NO_CONTAINER=1 ;;
        --container-setup) CONTAINER_SETUP=1 ;;
        *) echo "ERROR: unknown flag: $arg" >&2; exit 1 ;;
    esac
done

if [ $((DO_BIN + DO_APPIMAGE + DO_DEB + DO_RPM + CONTAINER_SETUP)) -eq 0 ]; then
    echo "Usage: $0 [--bin] [--appimage] [--deb] [--rpm] [--all] [--no-container] [--container-setup]" >&2
    exit 1
fi

if [ "$NO_CONTAINER" -eq 1 ]; then
    if [ "$DO_DEB" -eq 1 ] || [ "$DO_RPM" -eq 1 ] || [ "$CONTAINER_SETUP" -eq 1 ]; then
        echo "ERROR: --no-container is only valid with --bin and --appimage" >&2
        exit 1
    fi
fi

ENGINE=""
USER_ARGS=()

detect_engine() {
    [ -n "$ENGINE" ] && return 0
    ENGINE="$(command -v podman || command -v docker || true)"
    [ -n "$ENGINE" ] || { echo "ERROR: podman or docker is required" >&2; exit 1; }
    if [ "$(basename "$ENGINE")" = "podman" ]; then
        USER_ARGS=(--userns=keep-id)
    else
        USER_ARGS=(--user "$(id -u):$(id -g)")
    fi
}

build_image() {
    detect_engine
    echo "=== Building container image ($IMAGE) ==="
    "$ENGINE" build -t "$IMAGE" -f "$PROJECT_DIR/packaging/Containerfile.appimage" "$PROJECT_DIR/packaging"
}

ensure_image() {
    detect_engine
    "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || build_image
}

compile_bin() {
    local build_dir="$1"
    if [ ! -f "$build_dir/build.ninja" ]; then
        meson setup -Dfetch_cores=true "$build_dir" "$PROJECT_DIR"
    fi
    ninja -C "$build_dir"
}

package_appimage() {
    local build_dir="$1"
    local appdir="$build_dir/AppDir"
    local output="$OUT/Vector-${VERSION}-x86_64.AppImage"

    mkdir -p "$OUT"
    echo "=== AppImage (glibc $(ldd --version | head -1 | awk '{print $NF}')) ==="

    rm -rf "$appdir"
    mkdir -p "$appdir/usr/bin" \
             "$appdir/usr/lib" \
             "$appdir/usr/libexec/vector" \
             "$appdir/usr/share/applications" \
             "$appdir/usr/share/icons/hicolor/scalable/apps"

    cp "$build_dir/vector-adw" "$appdir/usr/bin/vector-adw"
    chmod +x "$appdir/usr/bin/vector-adw"

    for core in xray sing-box sing-box-lx; do
        local core_src=""
        for candidate in \
            "$build_dir/$core" \
            "${XDG_DATA_HOME:-$HOME/.local/share}/vector/bin/$core" \
            "/usr/local/libexec/vector/$core" \
            "/usr/libexec/vector/$core" \
            "$(command -v "$core" 2>/dev/null || true)"; do
            [ -n "$candidate" ] && [ -f "$candidate" ] && { core_src="$candidate"; break; }
        done

        if [ -z "$core_src" ]; then
            python3 "$PROJECT_DIR/fetch_cores.py" "$build_dir"
            [ -f "$build_dir/$core" ] && core_src="$build_dir/$core"
        fi

        [ -n "$core_src" ] || { echo "ERROR: core '$core' not found" >&2; exit 1; }
        cp "$core_src" "$appdir/usr/libexec/vector/$core"
        chmod +x "$appdir/usr/libexec/vector/$core"
    done

    local scalable_icon="$PROJECT_DIR/data/icons/hicolor/scalable/apps/io.github.dp0sk.Vector.svg"
    local symbolic_icon="$PROJECT_DIR/data/icons/hicolor/symbolic/apps/io.github.dp0sk.Vector-symbolic.svg"

    cp "$PROJECT_DIR/data/io.github.dp0sk.Vector.desktop" "$appdir/usr/share/applications/"
    cp "$scalable_icon" "$appdir/usr/share/icons/hicolor/scalable/apps/"
    if [ -f "$symbolic_icon" ]; then
        mkdir -p "$appdir/usr/share/icons/hicolor/symbolic/apps"
        cp "$symbolic_icon" "$appdir/usr/share/icons/hicolor/symbolic/apps/"
    fi
    if [ -f "$PROJECT_DIR/data/io.github.dp0sk.Vector.metainfo.xml" ]; then
        mkdir -p "$appdir/usr/share/metainfo"
        cp "$PROJECT_DIR/data/io.github.dp0sk.Vector.metainfo.xml" "$appdir/usr/share/metainfo/"
        ln -sf "io.github.dp0sk.Vector.metainfo.xml" "$appdir/usr/share/metainfo/io.github.dp0sk.Vector.appdata.xml"
    fi

    python3 - "$scalable_icon" "$appdir/io.github.dp0sk.Vector.png" << 'PYEOF' || true
import shutil, subprocess, sys
svg, png = sys.argv[1], sys.argv[2]
try:
    import gi
    gi.require_version('Rsvg', '2.0')
    gi.require_version('GdkPixbuf', '2.0')
    from gi.repository import Rsvg, GdkPixbuf
    Rsvg.Handle.new_from_file(svg).get_pixbuf().savev(png, 'png', [], [])
except Exception:
    for cmd in (
        ['rsvg-convert', '-w', '512', '-h', '512', svg, '-o', png],
        ['inkscape', svg, '-o', png, '-w', '512', '-h', '512'],
        ['convert', '-background', 'none', '-size', '512x512', svg, png],
    ):
        if shutil.which(cmd[0]) and subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            break
PYEOF

    if [ -f "$appdir/io.github.dp0sk.Vector.png" ]; then
        mkdir -p "$appdir/usr/share/icons/hicolor/512x512/apps"
        cp "$appdir/io.github.dp0sk.Vector.png" "$appdir/usr/share/icons/hicolor/512x512/apps/io.github.dp0sk.Vector.png"
        ln -sf "io.github.dp0sk.Vector.png" "$appdir/.DirIcon"
    else
        ln -sf "io.github.dp0sk.Vector.svg" "$appdir/.DirIcon"
    fi

    cp "$scalable_icon"                                  "$appdir/io.github.dp0sk.Vector.svg"
    cp "$PROJECT_DIR/data/io.github.dp0sk.Vector.desktop" "$appdir/io.github.dp0sk.Vector.desktop"

    local pattern="/libsoup-3\.0\.so|/libjson-glib-1\.0\.so|/libqrencode\.so"
    ldd "$build_dir/vector-adw" | grep "=>" | awk '{print $3}' | sort -u | while read -r lib; do
        [ -n "$lib" ] && [ -f "$lib" ] || continue
        echo "$lib" | grep -qE "$pattern" && cp -n "$lib" "$appdir/usr/lib/" || true
    done

    cat > "$appdir/AppRun" << 'EOF'
#!/usr/bin/env bash
set -e
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
[ -d "$HERE/usr/lib/gio/modules" ] && export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
exec "$HERE/usr/bin/vector-adw" "$@"
EOF
    chmod +x "$appdir/AppRun"

    local tool="$BUILD_ROOT/appimagetool-x86_64.AppImage"
    if [ ! -f "$tool" ]; then
        curl -fsSL -o "$tool" \
            "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
        chmod +x "$tool"
    fi

    rm -f "$output"
    ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" -n "$appdir" "$output"
}

build_deb() {
    ensure_image
    mkdir -p "$OUT"
    echo "=== deb (Debian 13) ==="
    "$ENGINE" run --rm -u 0 \
        -e VERSION="$VERSION" \
        -e OUT="/src/build/packages" \
        -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
        -v "$PROJECT_DIR":/src:Z \
        "$IMAGE" bash /src/packaging/deb/build.sh
}

build_rpm() {
    detect_engine
    mkdir -p "$OUT"
    echo "=== rpm (Fedora $FEDORA_RELEASE) ==="
    grep -q "^Version:\s*$VERSION$" "$PROJECT_DIR/packaging/rpm/vector.spec" \
        || { echo "ERROR: packaging/rpm/vector.spec Version is not $VERSION" >&2; exit 1; }

    local tarball="$OUT/vector-adw-$VERSION.tar.gz"
    tar --transform="s,^\.,vector-adw-$VERSION," \
        --exclude-vcs \
        --exclude='./build' \
        --exclude='./build-appimage' \
        --exclude='./build-packages' \
        --exclude='./.zcode' \
        -czf "$tarball" -C "$PROJECT_DIR" .
    trap "rm -f $(printf '%q' "$tarball")" EXIT

    "$ENGINE" run --rm \
        -e VERSION="$VERSION" \
        -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
        -v "$PROJECT_DIR":/src:Z \
        "registry.fedoraproject.org/fedora:$FEDORA_RELEASE" bash -euo pipefail -c '
            dnf -y -q install rpm-build dnf-plugins-core >/dev/null
            dnf -y -q builddep /src/packaging/rpm/vector.spec >/dev/null
            mkdir -p ~/rpmbuild/SOURCES
            cp "/src/build/packages/vector-adw-${VERSION}.tar.gz" ~/rpmbuild/SOURCES/
            rpmbuild -bb /src/packaging/rpm/vector.spec
            cp ~/rpmbuild/RPMS/*/vector-adw-*.rpm /src/build/packages/
        '

    rm -f "$tarball"
    trap - EXIT
}

[ "$CONTAINER_SETUP" -eq 1 ] && build_image

if [ "$DO_BIN" -eq 1 ] || [ "$DO_APPIMAGE" -eq 1 ]; then
    if [ "$NO_CONTAINER" -eq 1 ]; then
        BUILD_DIR="${BUILD_DIR:-$BUILD_ROOT/host}"
        compile_bin "$BUILD_DIR"
        if [ "$DO_BIN" -eq 1 ]; then
            mkdir -p "$BUILD_ROOT"
            cp -f "$BUILD_DIR/vector-adw" "$BUILD_ROOT/vector-adw"
        fi
        [ "$DO_APPIMAGE" -eq 1 ] && package_appimage "$BUILD_DIR"
    else
        ensure_image
        mkdir -p "$OUT"
        INNER=(--no-container)
        [ "$DO_BIN" -eq 1 ] && INNER+=(--bin)
        [ "$DO_APPIMAGE" -eq 1 ] && INNER+=(--appimage)
        "$ENGINE" run --rm "${USER_ARGS[@]}" \
            -e IN_CONTAINER=1 \
            -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
            -e HOME=/tmp \
            -e BUILD_DIR=/src/build/container \
            -v "$PROJECT_DIR":/src:Z -w /src \
            "$IMAGE" bash /src/build.sh "${INNER[@]}"
    fi
fi

[ "$DO_DEB" -eq 1 ] && build_deb
[ "$DO_RPM" -eq 1 ] && build_rpm

if [ -z "${IN_CONTAINER:-}" ]; then
    [ "$DO_BIN" -eq 1 ] && ls -lh "$BUILD_ROOT/vector-adw"
    if [ "$DO_APPIMAGE" -eq 1 ] || [ "$DO_DEB" -eq 1 ] || [ "$DO_RPM" -eq 1 ]; then
        ls -lh "$OUT"
    fi
fi