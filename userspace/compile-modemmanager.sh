#!/bin/bash
set -e

MM_VERSION="1.22.0"
LIBQMI_VERSION="1.34.0"

cd /tmp

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

dh_make --createorig -s -p libqmi_${LIBQMI_VERSION} -y

echo -e "override_dh_auto_configure:\n\tdh_auto_configure -- --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu -Dmbim_qmux=false -Dqrtr=false" >> debian/rules

dpkg-buildpackage -us -uc -nc

mv ../libqmi*.deb /tmp/libqmi.deb

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

dh_make --createorig -s -p modemmanager_${MM_VERSION} -y


cat <<EOF >> debian/rules
override_dh_auto_configure:
    dh_auto_configure -- \
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
EOF
sed -i 's/^    /\t/' debian/rules

dpkg-buildpackage -us -uc -nc

mv ../modemmanager*.deb /tmp/modemmanager.deb
