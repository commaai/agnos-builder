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
    libcurl4-openssl-dev \
    libczmq-dev \
    libdbus-1-dev \
    libffi-dev \
    libfreetype6-dev \
    libglib2.0-0t64 \
    libi2c-dev \
    liblzma-dev \
    libomp-dev \
    libportaudio2 \
    libsqlite3-dev \
    libusb-1.0-0-dev \
    libuv1-dev \
    locales \
    pkg-config \
    wget \
    zlib1g-dev
