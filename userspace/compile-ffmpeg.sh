#!/bin/bash -e

# Install ffmpeg (the one from the ubuntu repos doesn't work with our libOpenCL)
cd /tmp
wget https://ffmpeg.org/releases/ffmpeg-4.2.2.tar.bz2
tar xvf ffmpeg-4.2.2.tar.bz2
cd ffmpeg-4.2.2

./configure --enable-shared --disable-static
make -j$(nproc)

checkinstall -yD --install=no --pkgname=ffmpeg
mv ffmpeg*.deb /tmp/ffmpeg.deb
