#!/bin/bash -e

# Patched qtwayland that outputs a fixed screen size
# Clone qtwayland submodule, checkout v5.15.10-lts-lgpl, apply patch, qmake, make

cd /tmp
git clone --branch v5.15.10-lts-lgpl https://github.com/qt/qtwayland.git
cd qtwayland

git apply /tmp/agnos/patch

mkdir /tmp/build && cd /tmp/build
qmake /tmp/qtwayland

export MAKEFLAGS="-j$(nproc)"
make

# TODO remove "--fstrans=no" when checkinstall is fixed
checkinstall -yD --install=no --fstrans=no --pkgversion="5.15.10" --pkgname=qtwayland5 --pkgarch=arm64 --replaces=qtwayland5,libqt5waylandclient5,libqt5waylandcompositor5
mv qtwayland5*.deb /tmp/qtwayland5.deb
