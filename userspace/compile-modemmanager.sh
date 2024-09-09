#!/bin/bash
set -e

MM_VERSION="1.22.0"
LIBQMI_VERSION="1.34.0"

cd /tmp

# meson support for checkinstall
git clone https://github.com/keithbowes/meson-install.git

# libqmi
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

# ModemManager
cd /tmp

git clone -b $MM_VERSION --depth 1 https://gitlab.freedesktop.org/mobile-broadband/ModemManager.git

apt-get install -y --no-install-recommends \
      cmake \
      gettext \
      libdbus-1-dev \
      libpolkit-gobject-1-dev \
      libsystemd-dev \
      udev

apt-get -o Dpkg::Options::="--force-overwrite" install -yq /tmp/libqmi.deb

cd ModemManager
meson setup build \
      --prefix=/usr \
      --libdir=/usr/lib/aarch64-linux-gnu \
      --sysconfdir=/etc \
      --buildtype=release \
      -Dqmi=true \
      -Dmbim=false \
      -Dqrtr=false \
      -Dplugin_foxconn=disabled \
      -Dplugin_dell=disabled \
      -Dplugin_altair_lte=disabled \
      -Dplugin_fibocom=disabled

ninja -C build

cd build
checkinstall -yD --install=no --fstrans=no --pkgname=modemmanager /tmp/meson-install/meson-install
mv modemmanager*.deb /tmp/modemmanager.deb
