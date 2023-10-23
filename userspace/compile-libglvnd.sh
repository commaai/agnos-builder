#!/bin/bash

apt update && apt install -y libxext-dev libx11-dev x11proto-gl-dev ninja-build meson

cd /tmp
git clone https://gitlab.freedesktop.org/glvnd/libglvnd.git
cd libglvnd

./autogen.sh
./configure

export MAKEFLAGS="-j$(nproc)"
make

checkinstall -yD --install=no --pkgname=libglvnd
mv libglvnd*.deb /tmp/libglvnd.deb
