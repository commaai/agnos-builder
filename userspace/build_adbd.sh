#!/bin/bash -e

# Debian's Linux port of AOSP adbd, built against Ubuntu's Android libraries.
mkdir -p /tmp/adbd-build
cd /tmp/adbd-build
url=https://deb.debian.org/debian/pool/main/a/android-platform-tools
curl -fsSLO "$url/android-platform-tools_34.0.5.orig.tar.xz"
curl -fsSLO "$url/android-platform-tools_34.0.5-12.debian.tar.xz"
echo '4893f6a85b205f1df2c35cde5d6ca3bedd5e9f19afdb3b5ac781e647aa2243f4  android-platform-tools_34.0.5.orig.tar.xz
3cc7d24e24c6b38f641f4ab13742ba86506aa6f15ce920c159c4ef8a1eefd722  android-platform-tools_34.0.5-12.debian.tar.xz' | sha256sum -c
tar -xf android-platform-tools_34.0.5.orig.tar.xz --strip-components=1
tar -xf android-platform-tools_34.0.5-12.debian.tar.xz
while read -r patch; do
  patch -p1 < "debian/patches/$patch"
done < debian/patches/series
patch -p1 < /tmp/agnos/adbd-linux.patch

mkdir -p debian/out/system
(cd packages/modules/adb/proto && protoc --cpp_out=. ./*.proto)
export DEB_HOST_MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
export PLATFORM_TOOLS_VERSION=34.0.5 DEB_VERSION=34.0.5-12
export CXX=clang++
export CXXFLAGS='-Os -std=gnu++20 -fPIC -ffunction-sections -fdata-sections'
export CPPFLAGS='-DNDEBUG -UDEBUG -fno-exceptions -fno-strict-aliasing'
export LDFLAGS='-Wl,--gc-sections -Wl,-z,relro,-z,now'
make -j"$(nproc)" -f debian/system/libadb.mk
make -j"$(nproc)" -f debian/system/libcrypto_utils.mk
make -j"$(nproc)" -f debian/system/adbd.mk
install -D -m 755 debian/out/system/adbd /tmp/agnos/adbd
strip /tmp/agnos/adbd
