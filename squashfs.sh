#!/bin/bash
set -ex

EXT4_IMG="output/system.img"
SQUASHFS_IMG="output/system.squashfs"
MOUNT_POINT="/tmp/agnos-rootfs"

mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$EXT4_IMG" "$MOUNT_POINT"

sudo mksquashfs "$MOUNT_POINT" "$SQUASHFS_IMG" -comp xz -b 1M

sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
