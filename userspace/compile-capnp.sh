#!/bin/bash -e

VERSION=1.0.2

# Install build requirements
apt-get update && apt-get install -yq --no-install-recommends \
    libc6-dev \
    libssl-dev \
    zlib1g-dev

# Build capnproto
cd /tmp
wget https://capnproto.org/capnproto-c++-${VERSION}.tar.gz
tar xvf capnproto-c++-${VERSION}.tar.gz
cd capnproto-c++-${VERSION}

dh_make --createorig -s -p capnproto_${VERSION} -y

dpkg-buildpackage -us -uc -nc

mv ../capnproto*.deb /tmp/capnproto.deb
