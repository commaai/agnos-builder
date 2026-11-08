#!/bin/bash -e

echo "Installing openpilot dependencies"

# Install necessary libs
apt-get update
apt-get install --no-install-recommends -yq \
    clang-20 \
    curl \
    libdbus-1-dev \
    libdrm-dev \
    libgbm-dev \
    libglib2.0-0t64 \
    libportaudio2 \
    make \
    pkg-config \
    wget
