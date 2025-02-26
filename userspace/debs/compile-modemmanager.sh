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

cp /tmp/agnos/libqmi_rules debian/rules

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

cp /tmp/agnos/modemmanager_rules debian/rules

dpkg-buildpackage -us -uc -nc

mv ../modemmanager*.deb /tmp/modemmanager.deb
