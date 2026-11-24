#!/usr/bin/env python3
"""Fetch the proxy core binaries into a directory.

All three cores are pinned releases, each archive checked against its
SHA-256: xray-core, sing-box and sing-box-lx (sing-box fork with AmneziaWG,
github.com/Leadaxe/sing-box-lx).

To bump a core, change its version and the SHA-256 of each archive:
- xray: the "SHA2-256" line of the release's <archive>.dgst files;
- sing-box: the asset "digest" in the GitHub API
  (api.github.com/repos/SagerNet/sing-box/releases/tags/v<version>);
- sing-box-lx: the release's SHA256SUMS.
"""

import hashlib
import io
import os
import platform
import sys
import tarfile
import urllib.request
import zipfile

# machine -> (xray arch, sing-box arch)
ARCH = {"x86_64": ("64", "amd64"), "aarch64": ("arm64-v8a", "arm64")}

XRAY_VERSION = "26.11.9"
XRAY_SHA256 = {
    "64": "b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82",
    "arm64-v8a": "64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be",
}

SING_BOX_VERSION = "1.14.4"
SING_BOX_SHA256 = {
    "amd64": "699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968",
    "arm64": "436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26",
}

SING_BOX_LX_VERSION = "1.14.4-lx.33"
SING_BOX_LX_SHA256 = {
    "amd64": "b2953ad0bafa71c307de768f95c4c83a658a84f3e24de441b15d968ad017064f",
    "arm64": "1d39b9542bbdad6ffeec4cc13d9bb581311d7605231ac88c098ab813dd80539c",
}


def download_checked(url, sha256):
    req = urllib.request.Request(url, headers={"User-Agent": "vector-build"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        blob = resp.read()
    digest = hashlib.sha256(blob).hexdigest()
    if digest != sha256:
        sys.exit(f"fetch_cores: {url}: SHA-256 mismatch ({digest})")
    return blob


def write(outdir, name, data):
    path = os.path.join(outdir, name)
    with open(path, "wb") as f:
        f.write(data)
    os.chmod(path, 0o755)
    print(f"fetch_cores: wrote {path} ({len(data)} bytes)")


def sing_box_from_tar(blob):
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as t:
        member = next(m for m in t.getmembers() if m.name.endswith("/sing-box"))
        return t.extractfile(member).read()


def fetch_xray(outdir, arch):
    v = XRAY_VERSION
    url = f"https://github.com/XTLS/Xray-core/releases/download/v{v}/Xray-linux-{arch}.zip"
    blob = download_checked(url, XRAY_SHA256[arch])
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        write(outdir, "xray", z.read("xray"))


def fetch_singbox(outdir, arch):
    v = SING_BOX_VERSION
    url = f"https://github.com/SagerNet/sing-box/releases/download/v{v}/sing-box-{v}-linux-{arch}.tar.gz"
    write(outdir, "sing-box", sing_box_from_tar(download_checked(url, SING_BOX_SHA256[arch])))


def fetch_singbox_lx(outdir, arch):
    v = SING_BOX_LX_VERSION
    url = f"https://github.com/Leadaxe/sing-box-lx/releases/download/v{v}/sing-box-{v}-linux-{arch}.tar.gz"
    write(outdir, "sing-box-lx", sing_box_from_tar(download_checked(url, SING_BOX_LX_SHA256[arch])))


def main():
    # For meson configure: the pinned versions, one per line, in the order
    # sing-box, xray, sing-box-lx (no network used).
    if "--print-versions" in sys.argv[1:]:
        print(SING_BOX_VERSION)
        print(XRAY_VERSION)
        print(SING_BOX_LX_VERSION)
        return
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)
    machine = platform.machine()
    if machine not in ARCH:
        sys.exit(f"fetch_cores: unsupported architecture {machine}")
    xray_arch, sb_arch = ARCH[machine]
    fetch_xray(outdir, xray_arch)
    fetch_singbox(outdir, sb_arch)
    fetch_singbox_lx(outdir, sb_arch)


if __name__ == "__main__":
    main()
