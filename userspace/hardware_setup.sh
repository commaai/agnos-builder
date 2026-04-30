#!/bin/bash -e

# Setting up usr merged lib64 since it's not done by default (in 24.04-base)
# https://wiki.debian.org/UsrMerge
# https://www.freedesktop.org/wiki/Software/systemd/TheCaseForTheUsrMerge/
mkdir -p /usr/lib64
if [ -d /lib64 ] && [ ! -L /lib64 ]; then
  cp -a /lib64/. /usr/lib64/
  rm -rf /lib64
fi
ln -sfn usr/lib64 /lib64

# Install 16.04 version of libjson-c2
cd /tmp
wget http://ports.ubuntu.com/pool/main/j/json-c/libjson-c2_0.11-4ubuntu2.6_arm64.deb -O /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb
apt install -yq /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb

# Remove apt cache
rm -rf /var/lib/apt/lists/*

USERNAME=comma
adduser $USERNAME netdev
