#!/bin/bash -e

# Install capnproto
cd /tmp
VERSION=0.8.0
wget https://capnproto.org/capnproto-c++-${VERSION}.tar.gz
tar xvf capnproto-c++-${VERSION}.tar.gz
cd capnproto-c++-${VERSION}
CXXFLAGS="-fPIC -O2" ./configure

make -j$(nproc)

checkinstall -yD --install=no --pkgname=capnproto
mv capnproto*.deb /tmp/capnproto.deb
