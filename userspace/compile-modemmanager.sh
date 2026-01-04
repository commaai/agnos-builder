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
      -Doptimization=2 \
      -Dintrospection=false \
      -Dgtk_doc=false \
      -Dman=false \
      -Dbash_completion=false \
      -Dqmi=true \
      -Dmbim=false \
      -Dqrtr=false \
      -Dplugin_generic=enabled \
      -Dplugin_altair_lte=disabled \
      -Dplugin_anydata=disabled \
      -Dplugin_broadmobi=disabled \
      -Dplugin_cinterion=disabled \
      -Dplugin_dell=disabled \
      -Dplugin_dlink=disabled \
      -Dplugin_fibocom=disabled \
      -Dplugin_foxconn=disabled \
      -Dplugin_gosuncn=disabled \
      -Dplugin_haier=disabled \
      -Dplugin_huawei=disabled \
      -Dplugin_intel=disabled \
      -Dplugin_iridium=disabled \
      -Dplugin_linktop=disabled \
      -Dplugin_longcheer=disabled \
      -Dplugin_mbm=disabled \
      -Dplugin_motorola=disabled \
      -Dplugin_mtk=disabled \
      -Dplugin_nokia=disabled \
      -Dplugin_nokia_icera=disabled \
      -Dplugin_novatel=disabled \
      -Dplugin_novatel_lte=disabled \
      -Dplugin_option=disabled \
      -Dplugin_option_hso=disabled \
      -Dplugin_pantech=disabled \
      -Dplugin_qcom_soc=disabled \
      -Dplugin_quectel=enabled \
      -Dplugin_samsung=disabled \
      -Dplugin_sierra_legacy=disabled \
      -Dplugin_sierra=disabled \
      -Dplugin_simtech=disabled \
      -Dplugin_telit=disabled \
      -Dplugin_thuraya=disabled \
      -Dplugin_tplink=disabled \
      -Dplugin_ublox=disabled \
      -Dplugin_via=disabled \
      -Dplugin_wavecom=disabled \
      -Dplugin_x22x=disabled \
      -Dplugin_zte=disabled

ninja -C build

cd build
checkinstall -yD --install=no --fstrans=no --pkgname=modemmanager /tmp/meson-install/meson-install
mv modemmanager*.deb /tmp/modemmanager.deb
