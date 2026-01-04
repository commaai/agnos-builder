#!/bin/bash
set -e

MM_VERSION="1.22.0"

cd /tmp

# meson support for checkinstall
git clone https://github.com/keithbowes/meson-install.git

git clone -b $MM_VERSION --depth 1 https://gitlab.freedesktop.org/mobile-broadband/ModemManager.git

apt-get update && apt-get install -y --no-install-recommends \
      cmake \
      gettext \
      libdbus-1-dev \
      libpolkit-gobject-1-dev \
      libsystemd-dev \
      udev \
      && rm -rf /var/lib/apt/lists/*

cd ModemManager
# Speed optimizations: use plain buildtype with -O2, disable docs and introspection
meson setup build \
      --prefix=/usr \
      --libdir=/usr/lib/aarch64-linux-gnu \
      --sysconfdir=/etc \
      --buildtype=plain \
      -Doptimization=0 \
      -Dintrospection=false \
      -Dgtk_doc=false \
      -Dman=false \
      -Dbash_completion=false \
      -Dqmi=true \
      -Dmbim=false \
      -Dqrtr=false \
      -Dplugin_generic=disabled \
      -Dplugin_quectel=enabled \
      -Dall_plugins=false

ninja -C build

cd build
checkinstall -yD --install=no --fstrans=no --pkgname=modemmanager /tmp/meson-install/meson-install
mv modemmanager*.deb /tmp/modemmanager.deb
