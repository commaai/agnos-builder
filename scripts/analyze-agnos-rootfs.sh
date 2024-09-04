#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
cd $DIR

BUILD_DIR="$DIR/build"
ROOTFS_DIR="$BUILD_DIR/agnos-rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system.img"

# Setup mount container for macOS and CI support (namespace.so)
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
# echo "Total size:"
exec bash -c "du -sh \"$ROOTFS_DIR\" | sed 's|$ROOTFS_DIR|/|'"
# echo "Python env size:"
exec bash -c "du -sh -t 150M \"$ROOTFS_DIR\"/usr/local/* | sort -rh | sed 's|$ROOTFS_DIR||'"
# echo "Lib size:"
exec bash -c "du -sh -t 150M \"$ROOTFS_DIR\"/usr/lib/* | sort -rh | sed 's|$ROOTFS_DIR||'"
# echo "Others size:"
exec bash -c "find \"$ROOTFS_DIR/usr\" -mindepth 1 -maxdepth 1 -type d ! -path \"$ROOTFS_DIR/usr/local\" ! -path \"$ROOTFS_DIR/usr/lib\" -exec du -sh -t 150M {} + | sort -rh | sed 's|$ROOTFS_DIR||'"

# Unmount image
exec umount -l "$ROOTFS_DIR"
