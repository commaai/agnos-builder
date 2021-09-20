#!/bin/bash -e

# Build qtlocation with extra api responses parsed
cd /tmp
git clone https://github.com/commaai/qtlocation.git
cd qtlocation
git checkout d44ce6506d2dda542eb8e4b6fc06a6a6bf74bb48
qmake
make -j$(nproc)

checkinstall -yD --install=no --pkgname=qtlocation --pkgversion=0.0.1
cp qtlocation*.deb /tmp/qtlocation.deb
