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
    libdbus-1-dev \
    libffi-dev \
    libfreetype6-dev \
    libglib2.0-0t64 \
    liblzma-dev \
    libomp-dev \
    libportaudio2 \
    libsqlite3-dev \
    libusb-1.0-0-dev \
    libuv1-dev \
    locales \
    zlib1g-dev

echo "installing uv..."

export XDG_DATA_HOME="/usr/local"

curl -LsSf https://astral.sh/uv/install.sh | sh

# uv requires virtual env either managed or system before installing dependencies
PYTHON_VERSION="3.12"
uv venv $XDG_DATA_HOME/venv --seed --python-preference only-system --python=$PYTHON_VERSION
