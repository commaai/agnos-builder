#!/bin/bash -e

# Patched qtwayland that outputs a fixed screen size
# Clone qtwayland submodule, checkout, apply patch, qmake, make
VERSION=5.12.9

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
