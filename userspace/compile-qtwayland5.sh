#!/bin/bash -e

VERSION=5.12.9

# Install build requirements
dpkg --add-architecture armhf

apt-get update && apt-get install -yq --no-install-recommends \
    libc6:armhf \
    libdbus-1-3 \
    libegl-dev \
    libexpat1:armhf \
    libfontconfig-dev \
    libfreetype6 \
    libgles-dev \
    libglib2.0-dev \
    libharfbuzz-dev \
    libpcre2-dev \
    libwayland-dev \
    libxcomposite-dev \
    libxkbcommon-dev \
    zlib1g-dev

apt-get -o Dpkg::Options::="--force-overwrite" install -yq \
    /tmp/agnos/qt-5.12.8.deb \
    /tmp/agnos/libwayland-1.9.0-1.deb \
    /tmp/agnos/libicu66_66.1-2ubuntu2.1_arm64.deb \
    /tmp/agnos/libssl1.1_1.1.1f-1ubuntu2.22_arm64.deb \
    /tmp/agnos/libffi6_3.2.1-8_arm64.deb

# Patched qtwayland that outputs a fixed screen size
# Clone qtwayland submodule, checkout, apply patch, qmake, make
cd /tmp
git clone --branch v${VERSION} --depth 1 https://github.com/qt/qtwayland.git
cd qtwayland

git apply /tmp/agnos/patch-qtwayland-v5.12

# qtwayland is incorrectly built against libdl.so instead of libdl.so.2
# https://stackoverflow.com/a/75855054/639708
ln -s libdl.so.2 /usr/lib/aarch64-linux-gnu/libdl.so

mkdir /tmp/build && cd /tmp/build
qmake /tmp/qtwayland

export MAKEFLAGS="-j$(nproc)"
make

# remove "--fstrans=no" when checkinstall is fixed (still not fixed in 24.04)
# # https://bugs.launchpad.net/ubuntu/+source/checkinstall/+bug/78455
checkinstall -yD --install=no --fstrans=no --pkgversion="${VERSION}" --pkgname=qtwayland5 --pkgarch=arm64 --replaces=qtwayland5,libqt5waylandclient5,libqt5waylandcompositor5
mv qtwayland5*.deb /tmp/qtwayland5.deb
