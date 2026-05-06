#!/bin/bash
# Sourced by base_setup.sh — declares the openpilot apt dependencies so
# they're installed in the same apt-fast invocation as the base packages.
# See sync_openpilot_dependencies.sh for the openpilot pyproject sync flow.

OPENPILOT_DEPENDENCIES=(
    build-essential
    casync
    clang
    curl
    gpiod
    libarchive-dev
    libcurl4-openssl-dev
    libczmq-dev
    libdbus-1-dev
    libffi-dev
    libfreetype6-dev
    libglib2.0-0t64
    libi2c-dev
    liblzma-dev
    libomp-dev
    libportaudio2
    libsqlite3-dev
    libusb-1.0-0-dev
    libuv1-dev
    locales
    pkg-config
    wget
    zlib1g-dev
)
