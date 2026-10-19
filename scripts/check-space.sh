#!/usr/bin/env bash
set -e

# sudo apt install ncdu android-sdk-libsparse-utils

simg2img output/system.img build/system.img
mkdir -p build/agnos-rootfs
sudo mount build/system.img build/agnos-rootfs
sudo ncdu build/agnos-rootfs/ || true
sudo umount build/agnos-rootfs
