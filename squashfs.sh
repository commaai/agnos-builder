#!/bin/bash
set -ex

EXT4_IMG="output/system.img"
SQUASHFS_IMG="output/system.squashfs"
MOUNT_POINT="/tmp/agnos-rootfs"

mkdir -p "$MOUNT_POINT"
sudo umount $MOUNT_POINT || true
sudo mount -o loop "$EXT4_IMG" "$MOUNT_POINT"

rm -f $SQUASHFS_IMG*
sudo mksquashfs "$MOUNT_POINT" "$SQUASHFS_IMG.xz_arm" -comp xz -Xbcj arm -b 1M -Xdict-size 100%
for opt in "gzip" "xz" "lz4" "zstd"; do
  sudo mksquashfs "$MOUNT_POINT" "$SQUASHFS_IMG.$opt" -comp $opt -b 1M
done
du -hs output/system*

sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
