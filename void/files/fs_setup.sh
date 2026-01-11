#!/bin/bash
# Void Linux version - no systemd-tmpfiles

# Ensure the symlinks in the read only rootfs are
# backed by real files and directories on userdata.

# Create tmpfiles directories manually (replaces systemd-tmpfiles)
mkdir -p /var/run
chmod 0755 /var/run

mkdir -p /var/crash
chmod 0755 /var/crash

mkdir -p /var/tmp
chmod 1777 /var/tmp

mkdir -p /var/lib/logrotate
chmod 0755 /var/lib/logrotate

mkdir -p /var/spool/cron/atjobs
chmod 0755 /var/spool /var/spool/cron /var/spool/cron/atjobs

# /var/log/ tmpfs
mkdir -p /var/log/
chown root:root /var/log
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

# /data/persist
if [[ ! -d /data/persist ]]; then
  sudo cp -r /system/persist /data
fi

# Signal readiness for services that depend on the overlay
mkdir -p /run
chmod 0755 /run
touch /run/fs_setup.ready
