#!/bin/bash -e

VERSION=4.2.2

# Install build requirements (refresh apt cache since base image cleans lists)
apt-get update && apt-get install -yq --no-install-recommends \
    libass-dev \
    libfreetype6-dev \
    libgnutls28-dev \
    libmp3lame-dev \
    libsdl2-dev \
    libtool \
    libva-dev \
    libvdpau-dev \
    libvorbis-dev \
    libx264-dev \
    libxcb1-dev \
    libxcb-shm0-dev \
    libxcb-xfixes0-dev \
    liblzma-dev \
    rsync \
    texinfo \
    zlib1g-dev

# Build ffmpeg (the one from the ubuntu repos doesn't work with our libOpenCL)
cd /tmp
wget -q --show-progress https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.bz2
tar xf ffmpeg-${VERSION}.tar.bz2
cd ffmpeg-${VERSION}

# Optimize configuration for build speed
./configure \
    --enable-gpl \
    --enable-libx264 \
    --enable-shared \
    --disable-static \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-debug

# Use all available cores with memory management
make -j$(nproc) MAKEFLAGS="-j$(nproc)"

# remove "--fstrans=no" when checkinstall is fixed (still not fixed in 24.04)
checkinstall -yD --install=no --fstrans=no --pkgname=ffmpeg --pkgversion=${VERSION}
mv ffmpeg*.deb /tmp/ffmpeg.deb

# Cleanup to reduce layer size
rm -rf /tmp/ffmpeg-${VERSION}*
