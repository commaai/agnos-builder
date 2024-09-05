#!/bin/bash -e

VERSION=5.15.9

# Install build dependencies
apt-get update && apt-get install -yq --no-install-recommends \
    libdbus-1-3 \
    libgles-dev \
    libglib2.0-dev \
    libharfbuzz-dev \
    libpcre2-dev \
    libpng-dev \
    libpulse-dev

apt-get -o Dpkg::Options::="--force-overwrite" install -yq \
    /tmp/agnos/qt-5.12.8.deb \
    /tmp/agnos/libwayland-1.9.0-1.deb \
    /tmp/agnos/libicu66_66.1-2ubuntu2.1_arm64.deb \
    /tmp/agnos/libssl1.1_1.1.1f-1ubuntu2.22_arm64.deb \
    /tmp/agnos/libffi6_3.2.1-8_arm64.deb

source /usr/local/venv/bin/activate

# Build PyQt5 wheel
cd /tmp
wget https://files.pythonhosted.org/packages/5c/46/b4b6eae1e24d9432905ef1d4e7c28b6610e28252527cdc38f2a75997d8b5/PyQt5-${VERSION}.tar.gz
tar xf PyQt5-${VERSION}.tar.gz
cd PyQt5-${VERSION}

export MAKEFLAGS="-j$(nproc)"
pip wheel -w . --verbose --config-settings="--confirm-license=" --config-settings="--build-dir=/tmp/build/" .
