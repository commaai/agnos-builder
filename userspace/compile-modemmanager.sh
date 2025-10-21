#!/bin/bash
set -e

MM_VERSION="1.22.0"

cd /tmp

git clone -b $MM_VERSION --depth 1 https://gitlab.freedesktop.org/mobile-broadband/ModemManager.git

# Ensure apt is unlocked then install dependencies
export DEBIAN_FRONTEND=noninteractive
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock || true
rm -rf /var/lib/apt/lists/partial || true
(dpkg --configure -a) || true
apt-get update && apt-get install -y --no-install-recommends \
      cmake \
      gettext \
      libdbus-1-dev \
      libpolkit-gobject-1-dev \
      libsystemd-dev \
      udev

cd ModemManager
meson setup build \
      --prefix=/usr \
      --libdir=/usr/lib/aarch64-linux-gnu \
      --sysconfdir=/etc \
      --buildtype=release \
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
