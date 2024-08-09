#!/bin/bash
set -e

################################################################################
# Custom libwayland is created by combining libwayland client0, cursor0, server0
# and dev 1.9.0-1 from Ubuntu 16.04 (xenial) for both aarch64 and armhf, without
# getting into dependency hell.
################################################################################

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
TMP=$DIR/tmp
TMP_SRC=$TMP/libwayland-src-debs

# Create a new folder `libwayland-1.9.0-1` and put the metadata in
# `libwayland-1.9.0-1/DEBIAN/control`:

mkdir -p $TMP
cd $TMP
mkdir -p libwayland-1.9.0-1/DEBIAN

cat << EOF > libwayland-1.9.0-1/DEBIAN/control
Package: libwayland-xenial
Version: 1.9.0-1
Architecture: all
Maintainer: Andrei Radulescu andi.radulescu@gmail.com
Depends: libc6 (>= 2.17), libexpat1 (>= 2.0.1), libffi6 (>= 3.2)
Replaces: libwayland-dev, libwayland-client0, libwayland-cursor0, libwayland-server0
Installed-Size: 0
Homepage: https://comma.ai
Description: libwayland client0, cursor0, server0 and dev 1.9.0-1 from Ubuntu Xenial
EOF

# Download the official debs:
mkdir -p $TMP_SRC
cd $TMP_SRC

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libwayland-dev_1.9.0-1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libwayland-dev_1.9.0-1_armhf.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libwayland-client0_1.9.0-1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libwayland-client0_1.9.0-1_armhf.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libwayland-cursor0_1.9.0-1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libwayland-cursor0_1.9.0-1_armhf.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libwayland-server0_1.9.0-1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libwayland-server0_1.9.0-1_armhf.deb

# And unpack them:
for deb in *.deb; do dpkg-deb -R "$deb" "${deb%.deb}"; done

# Copy all files in libwayland-1.9.0-1
cd $TMP
cp -a $TMP_SRC/*/usr libwayland-1.9.0-1

# Package the deb and clean up everything else
dpkg-deb --root-owner-group --build "libwayland-1.9.0-1" "libwayland-1.9.0-1.deb"
mv libwayland-1.9.0-1.deb $DIR
rm -rf libwayland-1.9.0-1 $TMP_SRC
