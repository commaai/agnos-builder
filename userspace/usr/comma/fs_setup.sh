#!/bin/bash

# Ensure the symlinks in the read only rootfs are
# backed by real files and directories on userdata.

# tmpfiles
systemd-tmpfiles --create /usr/comma/tmpfiles.conf

# setup /home
mkdir -p /tmprw/home_work
mkdir -p /tmprw/home_upper
chmod 755 /tmprw/*
mount -t overlay overlay -o lowerdir=/usr/default/home,upperdir=/tmprw/home_upper,workdir=/tmprw/home_work /home

# /etc
mkdir -p /data/etc
touch /data/etc/timezone
touch /data/etc/localtime
mkdir -p /data/etc/NetworkManager/system-connections

# /data/media - NVME mount point
mkdir -p /data/media

# /data/ssh
mkdir -p /data/ssh
chown comma: /data/ssh

# /data/tmp - clear out
rm -rf /data/tmp/
mkdir -p /data/tmp/

# /data/persist
if [[ ! -d /data/persist ]]; then
  sudo cp -r /system/persist /data
fi
