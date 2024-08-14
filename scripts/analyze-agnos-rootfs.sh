#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
cd $DIR

BUILD_DIR="$DIR/build"
ROOTFS_DIR="$BUILD_DIR/agnos-rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system.img.raw"

# Setup mount container for macOS and CI support (namespace.so)
echo "Mounting agnos-rootfs"
docker build -f $DIR/Dockerfile.builder -t agnos-mount $DIR > /dev/null 2>&1
MOUNT_CONTAINER_ID=$(docker run -d --privileged -v $DIR:$DIR agnos-mount)
exec() {
  docker exec $MOUNT_CONTAINER_ID "$@"
}

# Cleanup container on exit
trap "docker container rm -f $MOUNT_CONTAINER_ID > /dev/null" EXIT

# Mount filesystem
exec mount "$ROOTFS_IMAGE" "$ROOTFS_DIR"

# Stats
exec bash -c "du -h \"$ROOTFS_DIR\"/* | sort -rh | head -n 20 | sed 's|$ROOTFS_DIR/||'"

# Unmount image
exec umount -l "$ROOTFS_DIR"
