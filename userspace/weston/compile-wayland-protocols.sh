#!/bin/bash -e

cd /tmp/weston
VERSION=1.20
wget -q https://wayland.freedesktop.org/releases/wayland-protocols-${VERSION}.tar.xz
tar xf wayland-protocols-${VERSION}.tar.xz && mv wayland-protocols-${VERSION} wayland-protocols
cd wayland-protocols

git apply /tmp/weston/patches/wayland-protocols/*.patch

autoreconf --install
./configure
make install
