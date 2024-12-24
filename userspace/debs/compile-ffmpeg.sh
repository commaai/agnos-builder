#!/bin/bash -e

VERSION=4.2.2

# Install build requirements
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
    libxcb1-dev \
    libxcb-shm0-dev \
    libxcb-xfixes0-dev \
    liblzma-dev \
    rsync \
    texinfo \
    zlib1g-dev

# Build ffmpeg (the one from the ubuntu repos doesn't work with our libOpenCL)
cd /tmp
wget https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.bz2
tar xvf ffmpeg-${VERSION}.tar.bz2
cd ffmpeg-${VERSION}

dh_make --createorig -s -p ffmpeg_${VERSION} -y

cp /tmp/agnos/ffmpeg_rules debian/rules

dpkg-buildpackage -us -uc -nc

 mv ../ffmpeg*.deb /tmp/ffmpeg.deb
