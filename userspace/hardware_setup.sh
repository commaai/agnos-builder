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

# Install 16.04 version of libjson-c2
cd /tmp
wget http://ports.ubuntu.com/pool/main/j/json-c/libjson-c2_0.11-4ubuntu2.6_arm64.deb -O /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb
apt install -yq /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb

# Remove apt cache
rm -rf /var/lib/apt/lists/*

USERNAME=comma
adduser $USERNAME netdev
