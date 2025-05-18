#!/bin/bash
set -e

LIBQMI_VERSION="1.36.0"

cd /tmp

# meson support for checkinstall
git clone https://github.com/keithbowes/meson-install.git

apt-get update && apt-get install -yq --no-install-recommends \
      bash-completion \
      gobject-introspection \
      gtk-doc-tools \
      help2man \
      libgirepository1.0-dev \
      libglib2.0-dev \
      libgudev-1.0-dev \
      meson \
      ninja-build \

git clone -b $LIBQMI_VERSION --depth 1 https://gitlab.freedesktop.org/mobile-broadband/libqmi.git
cd libqmi
meson setup build --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu -Dmbim_qmux=false -Dqrtr=false
ninja -C build

cd build
checkinstall -yD --install=no --fstrans=no --pkgname=libqmi /tmp/meson-install/meson-install
mv libqmi*.deb /tmp/libqmi.deb

apt-get -o Dpkg::Options::="--force-overwrite" install -yq /tmp/libqmi.deb
