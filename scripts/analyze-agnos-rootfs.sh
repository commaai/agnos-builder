#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
cd $DIR

BUILD_DIR="$DIR/build"
ROOTFS_DIR="$BUILD_DIR/agnos-rootfs"

# Setup mount container for macOS and CI support (namespace.so)
docker build -f $DIR/Dockerfile.builder -t agnos-mount $DIR > /dev/null 2>&1
MOUNT_CONTAINER_ID=$(docker run -d --privileged -v $DIR:$DIR agnos-mount)
exec() {
  docker exec $MOUNT_CONTAINER_ID "$@"
}

# Stats
exec bash -c "du -sh \"$ROOTFS_DIR\" | sed 's|$ROOTFS_DIR|/|'"
exec bash -c "du -sh -t 150M \"$ROOTFS_DIR\"/usr/local/* | sort -rh | sed 's|$ROOTFS_DIR||'"
exec bash -c "du -sh -t 150M \"$ROOTFS_DIR\"/usr/lib/* | sort -rh | sed 's|$ROOTFS_DIR||'"
exec bash -c "find \"$ROOTFS_DIR/usr\" -mindepth 1 -maxdepth 1 -type d ! -path \"$ROOTFS_DIR/usr/local\" ! -path \"$ROOTFS_DIR/usr/lib\" -exec du -sh -t 150M {} + | sort -rh | sed 's|$ROOTFS_DIR||'"
