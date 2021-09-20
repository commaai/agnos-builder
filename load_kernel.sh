#!/bin/bash -e
cd "$(dirname "$0")"
scp output/boot.img tici:/tmp/
#scp output/snd-soc-*.ko tici:/usr/comma/sound/
#scp output/wlan.ko tici:/usr/comma
ssh tici "sudo dd if=/tmp/boot.img of=/dev/disk/by-partlabel/boot_a && sudo dd if=/tmp/boot.img of=/dev/disk/by-partlabel/boot_b && sudo reboot"

