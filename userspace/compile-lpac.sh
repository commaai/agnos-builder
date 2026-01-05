#!/bin/bash
set -e

LPAC_VERSION="v2.2.1"

cd /tmp

git clone -b $LPAC_VERSION --depth 1 https://github.com/estkme-group/lpac.git

cd lpac

apt-get update && apt-get install -yq --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

./scripts/setup-debian.sh

# Speed optimizations: use Release build with -O2
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-O2" \
    -DCMAKE_CXX_FLAGS="-O2" \
    -DLPAC_WITH_APDU_QMI=ON \
    -DLPAC_WITH_APDU_PCSC=OFF \
    -DCPACK_GENERATOR=DEB .

make -j$(nproc) package

mv lpac*.deb /tmp/lpac.deb
