#!/bin/bash -e

VERSION=4.2.2

# Build ffmpeg without OpenCL (Qualcomm's libOpenCL doesn't support ICD interface)
cd /tmp
curl -L -o ffmpeg-${VERSION}.tar.bz2 https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.bz2
tar xvf ffmpeg-${VERSION}.tar.bz2
cd ffmpeg-${VERSION}

./configure \
  --enable-gpl \
  --enable-libx264 \
  --enable-shared \
  --disable-static \
  --disable-doc \
  --disable-opencl

make -j$(nproc)
make install
ldconfig

# Cleanup
cd /
rm -rf /tmp/ffmpeg-${VERSION}*
