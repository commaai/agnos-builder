#!/bin/bash -e

echo "Installing openpilot dependencies"

# Install necessary libs
apt-get update
apt-get install --no-install-recommends -yq \
    autoconf \
    automake \
    build-essential \
    bzip2 \
    casync \
    clang \
    clinfo \
    cmake \
    cppcheck \
    curl \
    darkstat \
    dkms \
    gcc-arm-none-eabi \
    gpiod \
    libarchive-dev \
    libass-dev \
    libbz2-dev \
    libcurl4-openssl-dev \
    libczmq-dev \
    libdbus-1-dev \
    libeigen3-dev \
    libffi-dev \
    libfreetype6-dev \
    libglib2.0-0t64 \
    libi2c-dev \
    libjpeg-dev \
    liblzma-dev \
    libomp-dev \
    libportaudio2 \
    libsqlite3-dev \
    libssl-dev \
    libsystemd-dev \
    libtool \
    libusb-1.0-0-dev \
    libuv1-dev \
    libvdpau-dev \
    libvorbis-dev \
    libzmq3-dev \
    libzstd-dev \
    locales \
    nethogs \
    ocl-icd-libopencl1 \
    opencl-headers \
    pkg-config \
    portaudio19-dev \
    texinfo \
    vnstat \
    wget \
    zlib1g-dev \
    zstd

# TODO: put these back when updating weston & removing old qt-5.12.8.deb
    # libqt5opengl5-dev \
    # libqt5sql5-sqlite \
    # libqt5svg5-dev \
    # libqt5multimedia5-plugins \
    # qml-module-qtquick2 \
    # qtbase5-dev \
    # qtchooser \
    # qt5-qmake \
    # qtbase5-dev-tools \
    # qtbase5-private-dev \
    # qtdeclarative5-dev \
    # qtdeclarative5-private-dev \
    # qtlocation5-dev \
    # qtmultimedia5-dev \
    # qtpositioning5-dev \
    # qtwayland5 \

# in case of uncertainty, qt5-default was a metapackage for:
    # qtbase5-dev
    # qtchooser
    # qt5-qmake
    # qtbase5-dev-tools
# more info: https://packages.ubuntu.com/focal/qt5-default
