#!/bin/bash -e

# sudo apt install ncdu

sudo mount build/system.img.raw build/agnos-rootfs
sudo ncdu build/agnos-rootfs/ || true
sudo umount build/agnos-rootfs
