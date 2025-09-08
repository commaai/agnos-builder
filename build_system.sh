#!/usr/bin/env bash
set -e

UBUNTU_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/"
UBUNTU_FILE="ubuntu-base-24.04.3-base-arm64.tar.gz"
UBUNTU_FILE_CHECKSUM="7b2dced6dd56ad5e4a813fa25c8de307b655fdabc6ea9213175a92c48dabb048"

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

BUILD_DIR="$DIR/build"
OUTPUT_DIR="$DIR/output"

ROOTFS_DIR="$BUILD_DIR/agnos-rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system.img"
OUT_IMAGE="$OUTPUT_DIR/system.img"

# Reduced image size for faster operations
ROOTFS_IMAGE_SIZE=4500M

# Create temp dir if non-existent
mkdir -p $BUILD_DIR $OUTPUT_DIR

# Parallel download and validation
download_and_validate() {
  if [ ! -f $UBUNTU_FILE ]; then
    echo "Downloading Ubuntu Base: $UBUNTU_FILE"
    # Use multiple connections and optimized settings for faster download
    if ! curl -C - -o $UBUNTU_FILE $UBUNTU_BASE_URL/$UBUNTU_FILE --silent --remote-time --fail --parallel --parallel-max 4 --connect-timeout 10; then
      echo "Download failed, please check Ubuntu releases: $UBUNTU_BASE_URL"
      exit 1
    fi
  fi

  # Validate checksum in parallel
  if [ "$(shasum -a 256 "$UBUNTU_FILE" | awk '{print $1}')" != "$UBUNTU_FILE_CHECKSUM" ]; then
    echo "Checksum mismatch, please check Ubuntu releases: $UBUNTU_BASE_URL"
    exit 1
  fi
}

# Run download/validation in background while we prepare other things
download_and_validate &
DOWNLOAD_PID=$!

# Setup qemu multiarch (only if needed)
if [ "$(uname -m)" = "x86_64" ]; then
  echo "Registering qemu-user-static"
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes > /dev/null
fi

# Wait for download to complete before Docker builds
wait $DOWNLOAD_PID

# Enable Docker BuildKit for faster builds
export DOCKER_BUILDKIT=1

# Build Docker images in parallel (remove redundant checks)
echo "Building Docker images in parallel..."
{
  BUILD="docker buildx build --load"
  if [ ! -z "$NS" ]; then
    BUILD="nsc build --load"
  fi
  echo "Building agnos-builder docker image"
  $BUILD -f Dockerfile.agnos -t agnos-builder $DIR --build-arg UBUNTU_BASE_IMAGE=$UBUNTU_FILE --platform=linux/arm64
} &
AGNOS_BUILD_PID=$!

{
  echo "Building agnos-meta-builder docker image" 
  docker buildx build --load -f Dockerfile.builder -t agnos-meta-builder $DIR \
    --build-arg UNAME=$(id -nu) \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g)
} &
META_BUILD_PID=$!

# Wait for both builds to complete
wait $AGNOS_BUILD_PID
wait $META_BUILD_PID

echo "Creating containers"
CONTAINER_ID=$(docker container create --entrypoint /bin/bash agnos-builder:latest)
MOUNT_CONTAINER_ID=$(docker run -d --privileged -v $DIR:$DIR agnos-meta-builder)

# Cleanup containers on possible exit
trap "echo \"Cleaning up containers:\"; \
docker container rm -f $CONTAINER_ID $MOUNT_CONTAINER_ID" EXIT

# Define functions for docker execution
exec_as_user() {
  docker exec -u $(id -nu) $MOUNT_CONTAINER_ID "$@"
}

exec_as_root() {
  docker exec $MOUNT_CONTAINER_ID "$@"
}

# Parallelize filesystem operations
echo "Setting up filesystem in parallel..."

# Create and format filesystem in background
{
  echo "Creating empty filesystem"
  exec_as_user fallocate -l $ROOTFS_IMAGE_SIZE $ROOTFS_IMAGE
  exec_as_user mkfs.ext4 $ROOTFS_IMAGE &> /dev/null
} &
FS_CREATE_PID=$!

# Export container filesystem in parallel
{
  echo "Extracting docker image"
  docker container export -o $BUILD_DIR/filesystem.tar $CONTAINER_ID
} &
EXPORT_PID=$!

# Wait for filesystem creation to complete, then mount
wait $FS_CREATE_PID
echo "Mounting empty filesystem"
exec_as_root mkdir -p $ROOTFS_DIR
exec_as_root mount $ROOTFS_IMAGE $ROOTFS_DIR

# Also unmount filesystem (overwrite previous trap)
trap "exec_as_root umount -l $ROOTFS_DIR &> /dev/null || true; \
echo \"Cleaning up containers:\"; \
docker container rm -f $CONTAINER_ID $MOUNT_CONTAINER_ID" EXIT

# Wait for export to complete, then extract
wait $EXPORT_PID
echo "Extracting filesystem"
exec_as_root tar -xf $BUILD_DIR/filesystem.tar -C $ROOTFS_DIR > /dev/null &
EXTRACT_PID=$!

# Remove .dockerenv while extraction happens
{
  wait $EXTRACT_PID
  echo "Removing .dockerenv file"
  exec_as_root rm -f $ROOTFS_DIR/.dockerenv
} &
CLEANUP_PID=$!

# Wait for cleanup to complete before network setup
wait $CLEANUP_PID

echo "Setting network configuration"
set_network_stuff() {
  cd $ROOTFS_DIR
  # Add hostname and hosts. This cannot be done in the docker container...
  HOST=comma
  bash -c "ln -sf /proc/sys/kernel/hostname etc/hostname"
  bash -c "echo \"127.0.0.1    localhost.localdomain localhost\" > etc/hosts"
  bash -c "echo \"127.0.0.1    $HOST\" >> etc/hosts"

  # Fix resolv config
  bash -c "ln -sf /run/systemd/resolve/stub-resolv.conf etc/resolv.conf"

  # Set capability for ping
  bash -c "setcap cap_net_raw+ep bin/ping"

  # Write build info
  DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
  bash -c "printf \"$GIT_HASH\n$DATETIME\n\" > BUILD"
}

GIT_HASH=${GIT_HASH:-$(git --git-dir=$DIR/.git rev-parse HEAD)}
exec_as_root bash -c "set -e; export ROOTFS_DIR=$ROOTFS_DIR GIT_HASH=$GIT_HASH; $(declare -f set_network_stuff); set_network_stuff"

# Unmount and finalize in parallel
{
  echo "Unmounting filesystem"
  exec_as_root umount -l $ROOTFS_DIR
} &
UNMOUNT_PID=$!

# Wait for unmount, then sparsify
wait $UNMOUNT_PID
echo "Sparsifying system image"
exec_as_user img2simg $ROOTFS_IMAGE $OUT_IMAGE

echo "Build completed successfully!"
