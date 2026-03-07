#!/bin/bash

# Directory containing the root filesystem
ROOTFS_DIR="build/agnos-rootfs"

# Output file name for the BTRFS image
IMAGE_FILE="agnos-rootfs.img"

# Temporary directory for the BTRFS filesystem
TEMP_DIR=$(mktemp -d)

# Size for the initial BTRFS image (adjust as necessary)
INITIAL_SIZE="10G"

# Compression to use for BTRFS (LZO is commonly supported, but ZSTD might be better if available)
COMPRESSION="lzo"  # or "zstd" if your kernel supports it

# Create a BTRFS filesystem in a loopback file
truncate -s "$INITIAL_SIZE" "$IMAGE_FILE"
mkfs.btrfs --compress=$COMPRESSION "$IMAGE_FILE"

# Mount the BTRFS filesystem
sudo mount -o compress=$COMPRESSION "$IMAGE_FILE" "$TEMP_DIR"

# Copy the rootfs into the mounted BTRFS filesystem
sudo rsync -aHAXx --info=progress2 "$ROOTFS_DIR"/ "$TEMP_DIR"/

# Unmount the filesystem
sudo umount "$TEMP_DIR"

# Attempt to shrink the filesystem
sudo losetup -fP "$IMAGE_FILE"
LOOPDEV=$(losetup -j "$IMAGE_FILE" | awk '{print $1}' | sed 's/://')
sudo btrfs filesystem resize min /dev/$LOOPDEV
sudo btrfs check --repair /dev/$LOOPDEV
sudo losetup -d /dev/$LOOPDEV

# Resize the image file to the actual size of the filesystem
# Note: This step requires knowing or estimating the exact size needed
# Here, we'll use the size of the last block used by BTRFS
SIZE=$(sudo btrfs inspect-internal dump-super "$IMAGE_FILE" | grep "total bytes" | awk '{print $3}')
truncate -s "$SIZE" "$IMAGE_FILE"

# Clean up
rmdir "$TEMP_DIR"

echo "BTRFS image created and shrunk: $IMAGE_FILE"
