#!/bin/bash -e
cd "$(dirname "$0")"

DEVICE=${DEVICE:-comma-ethernet}

scp output/boot.img output/*.ko $DEVICE:/data/tmp/
ssh $DEVICE <<EOF
sudo dd if=/data/tmp/boot.img of=/dev/disk/by-partlabel/boot_a
sudo dd if=/data/tmp/boot.img of=/dev/disk/by-partlabel/boot_b

sudo mount -o rw,remount /
sudo mv /data/tmp/wlan.ko /usr/comma/wlan.ko
rm -rf /data/tmp/*
sudo mount -o ro,remount / || true
EOF
