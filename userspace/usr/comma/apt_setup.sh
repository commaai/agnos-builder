#!/bin/bash -e

sudo mount -o rw,remount /
sudo resize2fs $(findmnt -n -o SOURCE /) &>/dev/null || sudo resize2fs $(findmnt -n -o SOURCE /)
sudo mount -o remount,size=1500M /var
sudo cp -r /usr/default/var/lib/dpkg /var/lib/
sudo sed -i '/bionic/s/^/#/' /etc/apt/sources.list
sudo sed -i '/hirsute/s/^/#/' /etc/apt/sources.list
