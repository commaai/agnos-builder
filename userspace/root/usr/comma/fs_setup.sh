#!/bin/bash

# Ensure the symlinks in the read only rootfs are
# backed by real files and directories on userdata.

# tmpfiles
systemd-tmpfiles --create /usr/comma/tmpfiles.conf

# /var/log/ tmpfs
mkdir -p /var/log/
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

# /cache
chown -R comma:comma /cache/

# /data/ssh
mkdir -p /data/ssh
chown comma: /data/ssh

# /data/tmp - clear out
rm -rf /data/tmp/
mkdir -p /data/tmp/

# /data/persist - served to the modem and DSPs through /system/rfs
mkdir -p /data/persist/hlos_rfs/shared /data/persist/rfs/shared \
  /data/persist/rfs/msm/adsp /data/persist/rfs/msm/mpss
