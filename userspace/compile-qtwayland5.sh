#!/bin/bash -e

# Patched qtwayland that outputs a fixed screen size
# Clone qtwayland submodule, checkout 5.12.9 (5.12.8 leaks timers, see https://bugreports.qt.io/browse/QTBUG-82914), apply patch, qmake, make

apt update && apt install -y qt5-qmake qtbase5-dev qtbase5-dev-tools

cd /tmp
git clone --branch v5.12.9 https://github.com/qt/qtwayland.git
cd qtwayland

git apply /tmp/agnos/patch

mkdir /tmp/build && cd /tmp/build
qmake /tmp/qtwayland

export MAKEFLAGS="-j$(nproc)"
make

checkinstall -yD --install=no --pkgversion="5.12.8" --pkgname=qtwayland5 --pkgarch=arm64 --replaces=qtwayland5,libqt5waylandclient5,libqt5waylandcompositor5
mv qtwayland5*.deb /tmp/qtwayland5.deb
