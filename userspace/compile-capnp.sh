#!/bin/bash -e

# Install capnproto
cd /tmp
VERSION=1.0.2
wget https://capnproto.org/capnproto-c++-${VERSION}.tar.gz
tar xvf capnproto-c++-${VERSION}.tar.gz
cd capnproto-c++-${VERSION}
CXXFLAGS="-fPIC -O2" ./configure

make -j$(nproc)

# remove "--fstrans=no" when checkinstall is fixed (still not fixed in 24.04)
checkinstall -yD --install=no --fstrans=no --pkgname=capnproto
mv capnproto*.deb /tmp/capnproto.deb
