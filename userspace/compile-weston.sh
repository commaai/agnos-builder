#!/bin/bash -e

sudo apt update
sudo apt install -y xz-utils meson ninja-build pkg-config cmake libxkbcommon-dev libwayland-dev libpixman-1-dev libinput-dev libdrm-dev wayland-protocols libcairo2-dev libjpeg-dev libwebp-dev libegl1-mesa-dev libpam0g-dev libseat-dev liblcms2-dev libgbm-dev libva-dev libpipewire-0.3-dev freerdp2-dev libneatvnc-dev libx11-xcb-dev libxcb-composite0-dev libxcursor-dev libsystemd-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libpango1.0-dev libxml2-dev libxcb-dev libxcb-cursor-dev

# Variables
WESTON_DIR="weston"
BUILD_DIR="build"
INSTALL_DIR="/usr/local"
WESTON_VERSION="13.0.3"
WESTON_TAR="weston-${WESTON_VERSION}.tar.xz"
WESTON_URL="https://gitlab.freedesktop.org/wayland/weston/-/releases/${WESTON_VERSION}/downloads/${WESTON_TAR}"

# Download and extract Weston
if [ ! -d "$WESTON_DIR" ]; then
    curl -L -o "$WESTON_TAR" "$WESTON_URL"
    tar -xf "$WESTON_TAR"
    mv "weston-${WESTON_VERSION}" "$WESTON_DIR"
    rm "$WESTON_TAR"
fi

# Build Weston
cd $WESTON_DIR

meson setup $BUILD_DIR --prefix=$INSTALL_DIR \
    # -Ddeprecated-backend-fbdev=true \
    -Dbackend-drm=true \
    # -Dbackend-wayland=true \
    # -Dbackend-x11=true \
    # -Dbackend-headless=true \
    -Drenderer-gl=true
ninja -C $BUILD_DIR
# sudo ninja -C $BUILD_DIR install

echo "Weston $WESTON_VERSION has been built and installed successfully."
