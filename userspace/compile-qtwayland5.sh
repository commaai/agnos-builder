#!/bin/bash -e

VERSION=5.12.9

# Install build requirements
dpkg --add-architecture armhf

apt-get update && apt-get install -yq --no-install-recommends \
    libc6:armhf \
    libdbus-1-3 \
    libdouble-conversion3 \
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
    /tmp/agnos/libffi6_3.2.1-8_arm64.deb \
    && rm -rf /var/lib/apt/lists/*

# Patched qtwayland that outputs a fixed screen size
# Clone qtwayland submodule, checkout, apply patch, qmake, make
cd /tmp
git clone --branch v${VERSION} --depth 1 https://github.com/qt/qtwayland.git
cd qtwayland

git apply /tmp/agnos/patch-qtwayland-v5.12

# qtwayland is incorrectly built against libdl.so instead of libdl.so.2
# https://stackoverflow.com/a/75855054/639708
ln -s libdl.so.2 /usr/lib/aarch64-linux-gnu/libdl.so

qmake
export MAKEFLAGS="-j$(nproc)"
make

OUTPUT_DIR=/tmp/qtwayland5
mkdir $OUTPUT_DIR
make install INSTALL_ROOT=$OUTPUT_DIR

mkdir $OUTPUT_DIR/DEBIAN
cat << EOF > $OUTPUT_DIR/DEBIAN/control
Package: qtwayland5
Version: ${VERSION}-1
Architecture: all
Maintainer: Andrei Radulescu <andi.radulescu@gmail.com>
Replaces: qtwayland5, libqt5waylandclient5, libqt5waylandcompositor5
Installed-Size: `du -s $OUTPUT_DIR | awk '{print $1}'`
Homepage: https://comma.ai
Description: Patched qtwayland that outputs a fixed screen size
EOF

dpkg-deb --root-owner-group --build $OUTPUT_DIR /tmp/qtwayland5.deb
