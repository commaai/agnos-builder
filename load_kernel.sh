#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

DEVICE=${DEVICE:-comma-ethernet}

scp output/boot.img output/*.ko $DEVICE:/data/tmp/
ssh $DEVICE <<EOF
sudo dd if=/data/tmp/boot.img of=/dev/disk/by-partlabel/boot_a
sudo dd if=/data/tmp/boot.img of=/dev/disk/by-partlabel/boot_b

sudo mount -o rw,remount /
sudo resize2fs $(findmnt -n -o SOURCE /)
sudo mv /data/tmp/wlan.ko /usr/comma/wlan.ko
sudo mv /data/tmp/snd-soc-sdm845.ko /usr/comma/sound/snd-soc-sdm845.ko
sudo mv /data/tmp/snd-soc-wcd9xxx.ko /usr/comma/sound/snd-soc-wcd9xxx.ko
rm -rf /data/tmp/*
sudo mount -o ro,remount / || true
sudo reboot
EOF
