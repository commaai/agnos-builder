#!/bin/bash
set -e

MM_VERSION="1.22.0"
LIBQMI_VERSION="1.34.0"
PROVIDER_INFO_VERSION="20230416"

cd /tmp

apt-fast update
apt-fast install -y --no-install-recommends automake autoconf build-essential cmake

# TODO: clean up these build time dependencies
apt-fast install -y --no-install-recommends python3 python3-pip python3-setuptools python3-wheel ninja-build
pip3 install --user meson
export PATH=$PATH:/root/.local/bin

# build mobile-broadband-provider-info
apt-fast install -y --no-install-recommends xsltproc
git clone -b $PROVIDER_INFO_VERSION --depth 1 https://gitlab.gnome.org/GNOME/mobile-broadband-provider-info.git
cd mobile-broadband-provider-info
./autogen.sh
./configure
make install

# build libqmi
cd /tmp
apt-fast install -y --no-install-recommends libgudev-1.0-dev gobject-introspection libgirepository1.0-dev help2man bash-completion

git clone -b $LIBQMI_VERSION --depth 1 https://gitlab.freedesktop.org/mobile-broadband/libqmi.git
cd libqmi
meson setup build --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu -Dmbim_qmux=false -Dqrtr=false
ninja -C build
ninja -C build install

# build ModemManager
cd /tmp
apt install -y --no-install-recommends gettext libpolkit-gobject-1-dev libdbus-1-dev libsystemd-dev

git clone -b $MM_VERSION --depth 1 https://gitlab.freedesktop.org/mobile-broadband/ModemManager.git

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
ninja -C build install

# remove plugins we don't use, makes probing faster
mkdir -p /tmp/mm-plugins
mv /usr/lib/aarch64-linux-gnu/ModemManager/libmm-*.so /tmp/mm-plugins
cp /tmp/mm-plugins/*generic* /usr/lib/aarch64-linux-gnu/ModemManager/
cp /tmp/mm-plugins/*quectel* /usr/lib/aarch64-linux-gnu/ModemManager/

rm -rf /var/lib/apt/lists/*
