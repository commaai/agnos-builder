#!/bin/bash -e
cd "$(dirname "$0")"

DEVICE=tici-ethernet

scp output/boot.img $DEVICE:/tmp/
ssh $DEVICE "sudo dd if=/tmp/boot.img of=/dev/disk/by-partlabel/boot_a && sudo dd if=/tmp/boot.img of=/dev/disk/by-partlabel/boot_b && sudo reboot"
