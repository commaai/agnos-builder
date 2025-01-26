#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

DEVICE=${DEVICE:-comma-ethernet}

scp output/boot.img $DEVICE:/data/tmp/
ssh $DEVICE <<EOF
sudo dd if=/data/tmp/boot.img of=/dev/disk/by-partlabel/boot_a
sudo dd if=/data/tmp/boot.img of=/dev/disk/by-partlabel/boot_b

sudo reboot
EOF
