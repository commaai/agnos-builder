#!/usr/bin/env bash
set -e

VOID_ROOTFS_URL="https://repo-default.voidlinux.org/live/current/void-aarch64-ROOTFS-20250202.tar.xz"
VOID_ROOTFS_FILE="void-aarch64-ROOTFS-20250202.tar.xz"
VOID_ROOTFS_SHA256="01a30f17ae06d4d5b322cd579ca971bc479e02cc284ec1e5a4255bea6bac3ce6"

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ROOT_DIR="$(dirname "$DIR")"
cd "$ROOT_DIR"

BUILD_DIR="$ROOT_DIR/build"
OUTPUT_DIR="$ROOT_DIR/output"

ROOTFS_DIR="$BUILD_DIR/void-rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system.img"
OUT_IMAGE="$OUTPUT_DIR/system.img"

# the partition is 10G, but openpilot's updater didn't always handle the full size
# Increased from 4500M to 6G for Python packages
ROOTFS_IMAGE_SIZE=6G

# Create temp dir if non-existent
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Download Void rootfs if not done already
if [ ! -f "$VOID_ROOTFS_FILE" ]; then
  echo "Downloading Void Linux rootfs: $VOID_ROOTFS_FILE"
  if ! curl -C - -o "$VOID_ROOTFS_FILE" "$VOID_ROOTFS_URL" --silent --remote-time --fail; then
    echo "Download failed"
    exit 1
  fi
fi

# Check SHA256 sum
if [ "$(shasum -a 256 "$VOID_ROOTFS_FILE" | awk '{print $1}')" != "$VOID_ROOTFS_SHA256" ]; then
  echo "Checksum mismatch"
  exit 1
fi

# Setup qemu multiarch
if [ "$(uname -m)" = "x86_64" ]; then
  echo "Registering qemu-user-static"
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes > /dev/null
fi

# Check Dockerfile
export DOCKER_BUILDKIT=1
docker buildx build -f void/Dockerfile.void --check "$ROOT_DIR"

# Start build and create container
echo "Building void-agnos docker image"
BUILD="docker buildx build --load"
if [ -n "$NS" ]; then
  BUILD="nsc build --load"
fi
$BUILD -f void/Dockerfile.void -t void-agnos-builder "$ROOT_DIR" \
  --build-arg VOID_ROOTFS="$VOID_ROOTFS_FILE" \
  --platform=linux/arm64

echo "Creating void-agnos container"
CONTAINER_ID=$(docker container create --entrypoint /bin/sh void-agnos-builder:latest)

# Setup mount container for macOS and CI support
echo "Building agnos-meta-builder docker image"
docker buildx build --load -f Dockerfile.builder -t agnos-meta-builder "$ROOT_DIR" \
  --build-arg UNAME="$(id -nu)" \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)"

echo "Starting agnos-meta-builder container"
MOUNT_CONTAINER_ID=$(docker run -d --privileged -v "$ROOT_DIR:$ROOT_DIR" agnos-meta-builder)

# Cleanup containers on possible exit
trap "echo \"Cleaning up containers:\"; \
docker container rm -f $CONTAINER_ID $MOUNT_CONTAINER_ID" EXIT

# Define functions for docker execution
exec_as_user() {
  docker exec -u "$(id -nu)" "$MOUNT_CONTAINER_ID" "$@"
}

exec_as_root() {
  docker exec "$MOUNT_CONTAINER_ID" "$@"
}

# Create filesystem ext4 image
echo "Creating empty filesystem"
exec_as_user fallocate -l "$ROOTFS_IMAGE_SIZE" "$ROOTFS_IMAGE"
exec_as_user mkfs.ext4 "$ROOTFS_IMAGE" &> /dev/null

# Mount filesystem
echo "Mounting empty filesystem"
exec_as_root mkdir -p "$ROOTFS_DIR"
exec_as_root mount "$ROOTFS_IMAGE" "$ROOTFS_DIR"

# Also unmount filesystem (overwrite previous trap)
trap "exec_as_root umount -l $ROOTFS_DIR &> /dev/null || true; \
echo \"Cleaning up containers:\"; \
docker container rm -f $CONTAINER_ID $MOUNT_CONTAINER_ID" EXIT

# Extract image (pipe directly to avoid double I/O)
echo "Extracting docker image"
docker container export "$CONTAINER_ID" | docker exec -i "$MOUNT_CONTAINER_ID" tar -xf - -C "$ROOTFS_DIR"

# Avoid detecting as container
echo "Removing .dockerenv file"
exec_as_root rm -f "$ROOTFS_DIR/.dockerenv"

echo "Setting network stuff"
set_network_stuff() {
  cd "$ROOTFS_DIR"
  # Add hostname and hosts
  HOST=comma
  bash -c "ln -sf /proc/sys/kernel/hostname etc/hostname"
  bash -c "echo \"127.0.0.1    localhost.localdomain localhost\" > etc/hosts"
  bash -c "echo \"127.0.0.1    $HOST\" >> etc/hosts"

  # DNS: resolv.conf must be writable for NetworkManager
  # Docker mounts resolv.conf during build so we do this after export
  bash -c "rm -f etc/resolv.conf && ln -s /run/resolv.conf etc/resolv.conf"

  # Write build info
  DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
  bash -c "printf \"$GIT_HASH\n$DATETIME\n\" > BUILD"
}
GIT_HASH=${GIT_HASH:-$(git --git-dir="$ROOT_DIR/.git" rev-parse HEAD)}
exec_as_root bash -c "set -e; export ROOTFS_DIR=$ROOTFS_DIR GIT_HASH=$GIT_HASH; $(declare -f set_network_stuff); set_network_stuff"

# Unmount image
echo "Unmount filesystem"
exec_as_root umount -l "$ROOTFS_DIR"

# Sparsify system image
exec_as_user img2simg "$ROOTFS_IMAGE" "$OUT_IMAGE"

echo "Done!"
