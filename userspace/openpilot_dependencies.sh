#!/bin/bash -e

echo "Installing openpilot dependencies"

# Install necessary libs
apt-fast update
apt-fast install --no-install-recommends -yq \
    build-essential \
    casync \
    clang \
    curl \
    gpiod \
    libarchive-dev \
    libass-dev \
    libcurl4-openssl-dev \
    libffi-dev \
    libfreetype6-dev \
    libglfw3-dev \
    libglib2.0-0t64 \
    liblzma-dev \
    libomp-dev \
    libportaudio2 \
    libsdl2-dev \
    libsqlite3-dev \
    libtool \
    libusb-1.0-0-dev \
    libuv1-dev \
    libva-dev \
    libvdpau-dev \
    libvorbis-dev \
    locales \
    pkg-config \
    portaudio19-dev \
    texinfo \
    wget \
    xvfb \
    zlib1g-dev
