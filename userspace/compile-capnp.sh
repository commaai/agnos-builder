#!/bin/bash -e

VERSION=1.0.2

# Install build requirements
apt-get update && apt-get install -yq --no-install-recommends \
    libc6-dev \
    libssl-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Build capnproto
cd /tmp
wget https://capnproto.org/capnproto-c++-${VERSION}.tar.gz
tar xvf capnproto-c++-${VERSION}.tar.gz
cd capnproto-c++-${VERSION}
# Speed optimization: use -O2, disable tests
CXXFLAGS="-fPIC -O2" ./configure --disable-shared

make -j$(nproc) capnp capnpc

# remove "--fstrans=no" when checkinstall is fixed (still not fixed in 24.04)
# https://bugs.launchpad.net/ubuntu/+source/checkinstall/+bug/78455
checkinstall -yD --install=no --fstrans=no --pkgname=capnproto
mv capnproto*.deb /tmp/capnproto.deb
