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
    libglfw3-dev \
    libglib2.0-0t64 \
    libi2c-dev \
    libjpeg-dev \
    liblzma-dev \
    libomp-dev \
    libportaudio2 \
    libsdl2-dev \
    libsqlite3-dev \
    libssl-dev \
    libsystemd-dev \
    libtool \
    libusb-1.0-0-dev \
    libuv1-dev \
    libva-dev \
    libvdpau-dev \
    libvorbis-dev \
    libxcb-shm0-dev \
    libxcb-xfixes0-dev \
    libxcb1-dev \
    libzmq3-dev \
    libzstd-dev \
    locales \
    nethogs \
    ocl-icd-libopencl1 \
    ocl-icd-opencl-dev \
    opencl-headers \
    pkg-config \
    portaudio19-dev \
    texinfo \
    vnstat \
    wget \
    zlib1g-dev \
    zstd

# TODO: put these back when updating weston & removing old qt-5.12.8.deb
    # libqt5location5-plugin-mapboxgl \
    # libqt5opengl5-dev \
    # libqt5sql5-sqlite \
    # libqt5svg5-dev \
    # libqt5multimedia5-plugins \
    # qml-module-qtquick2 \
    # qt5-qmake \
    # qtbase5-dev \
    # qtbase5-dev-tools \
    # qtbase5-private-dev \
    # qtchooser \
    # qtdeclarative5-dev \
    # qtdeclarative5-private-dev \
    # qtlocation5-dev \
    # qtmultimedia5-dev \
    # qtpositioning5-dev \
    # qtwayland5 \
