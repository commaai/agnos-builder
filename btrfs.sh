#!/bin/bash
set -e

# Variables
ROOTFS_DIR="build/agnos-rootfs"
IMAGE_NAME="agnos-btrfs-test.img"
IMAGE_SIZE="4G"  # Adjust this according to your needs

# Check if the rootfs directory exists
if [ ! -d "$ROOTFS_DIR" ]; then
  echo "Error: $ROOTFS_DIR does not exist."
  exit 1
fi

# Create an empty image file
dd if=/dev/zero of=$IMAGE_NAME bs=1 count=0 seek=$IMAGE_SIZE

# Format the image with BTRFS
mkfs.btrfs -f -d compress -m compress $IMAGE_NAME

# Mount the image to a temporary directory
MOUNT_POINT=$(mktemp -d)
sudo mount -o loop $IMAGE_NAME $MOUNT_POINT

# Copy the rootfs to the mounted image
sudo cp -a $ROOTFS_DIR/* $MOUNT_POINT/

# Unmount the image
sudo umount $MOUNT_POINT

# Clean up the temporary mount point
rmdir $MOUNT_POINT

echo "BTRFS image $IMAGE_NAME created successfully."
