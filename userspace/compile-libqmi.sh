#!/bin/bash
set -e

LIBQMI_VERSION="1.36.0"

cd /tmp

git clone -b $LIBQMI_VERSION --depth 1 https://gitlab.freedesktop.org/mobile-broadband/libqmi.git
cd libqmi
meson setup build --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu -Dmbim_qmux=false -Dqrtr=false
ninja -C build

cd build
checkinstall -yD --install=no --fstrans=no --pkgname=libqmi /tmp/meson-install/meson-install
mv libqmi*.deb /tmp/libqmi.deb

apt-get -o Dpkg::Options::="--force-overwrite" install -yq /tmp/libqmi.deb
