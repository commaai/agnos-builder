#!/bin/bash

# Ensure the symlinks in the read only rootfs are
# backed by real files and directories on userdata.

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

# /data/persist
if [[ ! -d /data/persist ]]; then
  sudo cp -r /system/persist /data
fi
