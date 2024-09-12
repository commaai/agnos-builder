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

# avoid makeinfo: error parsing ./doc/t2h.pm: Undefined subroutine &Texinfo::Config::set_from_init_file called at ./doc/t2h.pm line 24.
# with --disable-htmlpages
# --disable-doc works too, disables building documentation completely
# https://gist.github.com/omegdadi/6904512c0a948225c81114b1c5acb875
# https://github.com/7Ji/archrepo/issues/10
./configure --enable-shared --disable-static --disable-htmlpages
make -j$(nproc)

# remove "--fstrans=no" when checkinstall is fixed (still not fixed in 24.04)
# # https://bugs.launchpad.net/ubuntu/+source/checkinstall/+bug/78455
checkinstall -yD --install=no --fstrans=no --pkgname=ffmpeg
mv ffmpeg*.deb /tmp/ffmpeg.deb
