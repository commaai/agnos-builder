#!/bin/bash -e

cd /tmp/weston
VERSION=2.4.101
wget -q https://dri.freedesktop.org/libdrm/libdrm-${VERSION}.tar.xz
tar xf libdrm-${VERSION}.tar.xz && mv libdrm-${VERSION} libdrm
cd libdrm

git apply /tmp/weston/patches/libdrm/*.patch

meson setup -Damdgpu=false -Dcairo-tests=false -Detnaviv=false -Dexynos=false -Dfreedreno=false -Dfreedreno-kgsl=false -Dinstall-test-programs=true -Dintel=false -Dlibkms=true -Dman-pages=false -Dnouveau=false -Domap=false -Dradeon=false -Dtegra=false -Dudev=false -Dvalgrind=false -Dvc4=false -Dvmwgfx=false build

ninja -v -C build -j$(nproc)

checkinstall -yD --install=yes --pkgname=libdrm --pkgversion="${VERSION}" ninja -v -C build -j$(nproc) install
mv libdrm*.deb /tmp/libdrm.deb
