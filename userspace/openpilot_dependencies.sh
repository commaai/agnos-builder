#!/bin/bash -e

echo "Installing openpilot dependencies"

# Install necessary libs
apt-fast update
apt-fast install --no-install-recommends -yq \
    autoconf \
    automake \
    build-essential \
    casync \
    clang \
    cmake \
    curl \
    darkstat \
    dkms \
    gpiod \
    libasound2-dev \
    libcurl4-openssl-dev \
    libdbus-1-dev \
    libdrm-dev \
    libffi-dev \
    libfreetype6-dev \
    libgbm-dev \
    libglib2.0-0t64 \
    libi2c-dev \
    liblzma-dev \
    libomp-dev \
    libportaudio2 \
    libsqlite3-dev \
    libsystemd-dev \
    libtool \
    libudev-dev \
    libusb-1.0-0-dev \
    libuv1-dev \
    libva-dev \
    libzmq5 \
    locales \
    nethogs \
    pkg-config \
    texinfo \
    vnstat \
    wget \
    zlib1g-dev
