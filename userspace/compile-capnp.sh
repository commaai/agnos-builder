#!/bin/bash -e

VERSION=1.0.2

# Ensure apt is unlocked and install build requirements
export DEBIAN_FRONTEND=noninteractive
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock || true
rm -rf /var/lib/apt/lists/partial || true
(dpkg --configure -a) || true
apt-get update && apt-get install -yq --no-install-recommends \
    libc6-dev \
    libssl-dev \
    zlib1g-dev

# Build capnproto with optimized settings
cd /tmp
wget -q --show-progress https://capnproto.org/capnproto-c++-${VERSION}.tar.gz
tar xf capnproto-c++-${VERSION}.tar.gz
cd capnproto-c++-${VERSION}

# Optimize for build speed (remove potentially incompatible flags)
CXXFLAGS="-fPIC -O2" ./configure

# Use all available cores and limit memory usage
make -j$(nproc) MAKEFLAGS="-j$(nproc)"

# remove "--fstrans=no" when checkinstall is fixed (still not fixed in 24.04)
# https://bugs.launchpad.net/ubuntu/+source/checkinstall/+bug/78455
checkinstall -yD --install=no --fstrans=no --pkgname=capnproto --pkgversion=${VERSION}
mv capnproto*.deb /tmp/capnproto.deb

# Cleanup to reduce layer size
rm -rf /tmp/capnproto-c++-${VERSION}*
