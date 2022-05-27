#!/bin/bash
set -e

MM_VERSION="1.18.8"
LIBQMI_VERSION="1.30.6"
PROVIDER_INFO_VERSION="20220511"

cd /tmp

# TODO: clean up these build time dependencies
apt install -y --no-install-recommends python3 python3-pip python3-setuptools python3-wheel ninja-build
pip3 install --user meson
export PATH=$PATH:/root/.local/bin

# build mobile-broadband-provider-info
apt install -y --no-install-recommends xsltproc
git clone -b $PROVIDER_INFO_VERSION --depth 1 https://gitlab.gnome.org/GNOME/mobile-broadband-provider-info.git
cd mobile-broadband-provider-info
./autogen.sh
./configure
make install

# build libqmi
cd /tmp
apt install -y --no-install-recommends libgudev-1.0-dev gobject-introspection libgirepository1.0-dev help2man bash-completion

git clone -b $LIBQMI_VERSION --depth 1 https://gitlab.freedesktop.org/mobile-broadband/libqmi.git
cd libqmi
meson setup build --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu -Dmbim_qmux=false -Dqrtr=false
ninja -C build
ninja -C build install

# build ModemManager
cd /tmp
apt install -y --no-install-recommends gettext libpolkit-gobject-1-dev

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
