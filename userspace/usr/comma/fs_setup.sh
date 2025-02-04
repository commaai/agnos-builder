#!/bin/bash

# Ensure the symlinks in the read only rootfs are
# backed by real files and directories on userdata.

# tmpfiles
systemd-tmpfiles --create /usr/comma/tmpfiles.conf

# /var/log/ tmpfs
mkdir -p /var/log/
chown root:syslog /var/log
mount -t tmpfs -o rw,nosuid,nodev,size=128M,mode=755 tmpfs /var/log

# setup /home
mkdir -p /rwtmp/home_work
mkdir -p /rwtmp/home_upper
chmod 755 /rwtmp/*
mount -t overlay overlay -o lowerdir=/usr/default/home,upperdir=/rwtmp/home_upper,workdir=/rwtmp/home_work /home

# /etc
mkdir -p /data/etc
touch /data/etc/timezone
touch /data/etc/localtime
mkdir -p /data/etc/netplan
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
