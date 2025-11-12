#!/bin/bash

# Variables
ROOTFS_DIR="build/agnos-rootfs"
IMAGE_NAME="agnos-btrfs-test.img"
IMAGE_SIZE="4G"  # Adjust this according to your needs

# Create an empty image file
dd if=/dev/zero of=$IMAGE_NAME bs=1 count=0 seek=$IMAGE_SIZE

# Format the image with BTRFS, enabling compression for both data and metadata
mkfs.btrfs -f $IMAGE_NAME

# Create a loop device and mount it
LOOP_DEVICE=$(sudo losetup -f --show $IMAGE_NAME)
MOUNT_POINT=$(mktemp -d)

# Enable compression for the filesystem
sudo mount -o loop,compress-force=zlib:15 $LOOP_DEVICE $MOUNT_POINT
#sudo mount -o loop,compress=zlib:15,compress-force=zlib:15 $LOOP_DEVICE $MOUNT_POINT
#sudo mount -o loop $LOOP_DEVICE $MOUNT_POINT

# Copy the rootfs to the mounted image
sudo cp -a $ROOTFS_DIR/* $MOUNT_POINT/

#sudo btrfs filesystem defragment -r -v -clzo $MOUNT_POINT

# Unmount the image
sudo umount $MOUNT_POINT

# Detach the loop device
sudo losetup -d $LOOP_DEVICE

# Clean up the temporary mount point
rmdir $MOUNT_POINT

echo "BTRFS image $IMAGE_NAME with compression created successfully."
du -hs $IMAGE_NAME
