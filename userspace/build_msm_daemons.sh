#!/bin/bash
set -euo pipefail

mkdir -p /tmp/msm-daemons /tmp/agnos/msm-daemons
cd /tmp/msm-daemons

fetch() {
  local repo=$1 tag=$2 revision=$3
  git -c advice.detachedHead=false clone --depth 1 --branch "$tag" "https://github.com/linux-msm/$repo.git"
  test "$(git -C "$repo" rev-parse HEAD)" = "$revision"
}

fetch qrtr v1.2 b51ffaf22707b6000ecfb894c5b750f3bb7843b2
fetch qmic v1.0 4574736afce75aa5eec1e1069a19563410167c9f
fetch rmtfs v1.3 b30a3eb38f9af283f18dbd3c7755653efc52c094
fetch tqftpserv v1.2 b6bb92d40cfffe28621abcf7bfaa6d99beea46cb

meson setup qrtr/build qrtr --prefix=/usr -Dqrtr-ns=enabled -Dsystemd-service=disabled
meson compile -C qrtr/build
meson install -C qrtr/build
ldconfig

make -C qmic -j"$(nproc)"
make -C qmic install prefix=/usr
make -C rmtfs -j"$(nproc)"

meson setup tqftpserv/build tqftpserv --prefix=/usr -Dsystemd-unit-prefix=/usr/lib/systemd/system
meson compile -C tqftpserv/build

root=/tmp/agnos/msm-daemons
DESTDIR="$root" meson install -C qrtr/build
install -D -m755 rmtfs/rmtfs "$root/usr/bin/rmtfs"
install -D -m755 tqftpserv/build/tqftpserv "$root/usr/bin/tqftpserv"
rm -rf "$root/usr/include" "$root/usr/lib/"*/pkgconfig
for repo in qrtr qmic rmtfs tqftpserv; do
  install -D -m644 "$repo/LICENSE" "$root/usr/share/doc/$repo/copyright"
  {
    printf 'Source: https://github.com/linux-msm/%s\n' "$repo"
    printf 'Revision: %s\n' "$(git -C "$repo" rev-parse HEAD)"
    printf 'Local modifications: none\n'
  } > "$root/usr/share/doc/$repo/SOURCES"
done
strip "$root/usr/bin/"* "$root/usr/lib/"*/libqrtr.so.1.2
