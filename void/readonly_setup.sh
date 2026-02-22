#!/bin/bash
set -e

# Setup symlinks to preserve non-volatile state on userdata

# /etc
rm -rf /etc/timezone /etc/localtime
ln -s /data/etc/timezone /etc/timezone
ln -s /data/etc/localtime /etc/localtime

rm -f /etc/ssh/ssh_host*

rm -rf /etc/NetworkManager/system-connections
ln -s /data/etc/NetworkManager/system-connections /etc/NetworkManager/system-connections
rm -rf /etc/netplan/
ln -s /data/etc/netplan/ /etc/netplan

# setup /usr/default for defaults
mkdir -p /usr/default/

rm -rf /var/cache/*
mv /var /usr/default && mkdir /var

mv /home /usr/default && mkdir /home

# setup mount points
rm -rf /tmp && mkdir /tmp
rm -rf /cache && mkdir /cache
rm -rf /systemrw && mkdir /systemrw
mkdir -p /rwtmp
