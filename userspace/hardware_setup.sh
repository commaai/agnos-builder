#!/bin/bash -e

# Install driver deb files (we're fine with overwriting stuff too)
cd /tmp/agnos/debs

# Setting up usr merged lib64 since it's not done by default (in 24.04-base)
# https://wiki.debian.org/UsrMerge
# https://www.freedesktop.org/wiki/Software/systemd/TheCaseForTheUsrMerge/
sudo mkdir /usr/lib64
sudo ln -s usr/lib64 /lib64

apt-get -o Dpkg::Options::="--force-overwrite" install -yq \
  ./agnos-base.deb \
  ./agnos-display_0.0.1.deb \
  ./agnos-wlan_0.0.3.deb

# agnos-display bundles the retired 32-bit Weston stack alongside the native
# Qualcomm drivers. Keep the native drivers for raylib and OpenCL.
rm -rf /usr/bin/weston* /usr/bin/wcap-decode /usr/bin/gbmtest \
  /usr/libexec/weston-* /usr/share/weston /usr/share/wayland-sessions/weston.desktop \
  /usr/lib/arm-linux-gnueabihf/weston
rm -f /usr/lib/arm-linux-gnueabihf/libEGL* \
  /usr/lib/arm-linux-gnueabihf/libGLES* \
  /usr/lib/arm-linux-gnueabihf/libOpenCL.so \
  /usr/lib/arm-linux-gnueabihf/libC2D2.so \
  /usr/lib/arm-linux-gnueabihf/libCB.so \
  /usr/lib/arm-linux-gnueabihf/libQTapGLES.so \
  /usr/lib/arm-linux-gnueabihf/libadreno_utils.so \
  /usr/lib/arm-linux-gnueabihf/libc2d30*.so \
  /usr/lib/arm-linux-gnueabihf/libeglSubDriverWayland.so \
  /usr/lib/arm-linux-gnueabihf/libgbm.so \
  /usr/lib/arm-linux-gnueabihf/libgsl.so \
  /usr/lib/arm-linux-gnueabihf/libllvm-glnext.so \
  /usr/lib/arm-linux-gnueabihf/libllvm-qcom.so \
  /usr/lib/arm-linux-gnueabihf/libq3dtools_*.so

# Install 16.04 version of libjson-c2
cd /tmp
wget http://ports.ubuntu.com/pool/main/j/json-c/libjson-c2_0.11-4ubuntu2.6_arm64.deb -O /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb
apt install -yq /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb

# Remove apt cache
rm -rf /var/lib/apt/lists/*

USERNAME=comma
adduser $USERNAME netdev
