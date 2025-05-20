#!/bin/bash
set -e

LPAC_VERSION="v2.2.1"

cd /tmp

git clone -b $LPAC_VERSION --depth 1 https://github.com/estkme-group/lpac.git

cd lpac

apt-get update && apt-get install -yq --no-install-recommends cmake

./scripts/setup-debian.sh

cmake \
    -DLPAC_WITH_APDU_QMI=ON \
    -DLPAC_WITH_APDU_PCSC=OFF \
    -DCPACK_GENERATOR=DEB .

make -j package

mv lpac*.deb /tmp/lpac.deb
