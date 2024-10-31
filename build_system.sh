#!/usr/bin/env bash
set -e

UBUNTU_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/"
UBUNTU_FILE="ubuntu-base-24.04.1-base-arm64.tar.gz"
UBUNTU_FILE_CHECKSUM="7700539236d24c31c3eea1d5345eba5ee0353a1bac7d91ea5720b399b27f3cb4"

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

BUILD_DIR="$DIR/build"
OUTPUT_DIR="$DIR/output"

ROOTFS_DIR="$BUILD_DIR/agnos-rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system.img"
OUT_IMAGE="$OUTPUT_DIR/system.img"

# the partition is 10G, but openpilot's updater didn't always handle the full size
# openpilot fix, shipped in 0.9.8 (8/18/24): https://github.com/commaai/openpilot/pull/33320
ROOTFS_IMAGE_SIZE=4200M

# Create temp dir if non-existent
mkdir -p $BUILD_DIR $OUTPUT_DIR

# Copy kernel modules
if ! ls $OUTPUT_DIR/*.ko >/dev/null 2>&1; then
  echo "Kernel modules missing. Run ./build_kernel.sh first"
  exit 1
fi
cp $OUTPUT_DIR/wlan.ko $DIR/userspace/usr/comma
cp $OUTPUT_DIR/snd*.ko $DIR/userspace/usr/comma/sound/

# Download Ubuntu Base if not done already
if [ ! -f $UBUNTU_FILE ]; then
  echo -e "Downloading Ubuntu Base: $UBUNTU_FILE"
  if ! curl -C - -o $UBUNTU_FILE $UBUNTU_BASE_URL/$UBUNTU_FILE --silent --remote-time --fail; then
    echo "Download failed, please check Ubuntu releases: $UBUNTU_BASE_URL"
    exit 1
  fi
fi

# Check SHA256 sum
if [ "$(shasum -a 256 "$UBUNTU_FILE" | awk '{print $1}')" != "$UBUNTU_FILE_CHECKSUM" ]; then
  echo "Checksum mismatch, please check Ubuntu releases: $UBUNTU_BASE_URL"
  exit 1
fi

# Setup qemu multiarch
if [ "$(uname -m)" = "x86_64" ]; then
  echo "Registering qemu-user-static"
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes > /dev/null
fi

# Check agnos-builder Dockerfile
export DOCKER_BUILDKIT=1
docker buildx build -f Dockerfile.agnos --check $DIR

# Start build and create container
echo "Building agnos-builder docker image"
BUILD="docker build"
if [ ! -z "$NS" ]; then
  BUILD="nsc build --load"
fi
$BUILD -f Dockerfile.agnos -t agnos-builder $DIR --build-arg UBUNTU_BASE_IMAGE=$UBUNTU_FILE --platform=linux/arm64
echo "Creating agnos-builder container"
CONTAINER_ID=$(docker container create --entrypoint /bin/bash agnos-builder:latest)

# Check agnos-meta-builder Dockerfile
docker buildx build -f Dockerfile.builder --check $DIR \
  --build-arg UNAME=$(id -nu) \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g)

# Setup mount container for macOS and CI support (namespace.so)
echo "Building agnos-meta-builder docker image"
docker buildx build -f Dockerfile.builder -t agnos-meta-builder $DIR \
  --build-arg UNAME=$(id -nu) \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g)
echo "Starting agnos-meta-builder container"
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

# Create filesystem ext4 image
echo "Creating empty filesystem"
exec_as_user fallocate -l $ROOTFS_IMAGE_SIZE $ROOTFS_IMAGE
exec_as_user mkfs.ext4 $ROOTFS_IMAGE &> /dev/null

# Mount filesystem
echo "Mounting empty filesystem"
exec_as_root mkdir -p $ROOTFS_DIR
exec_as_root mount $ROOTFS_IMAGE $ROOTFS_DIR

# Also unmount filesystem (overwrite previous trap)
trap "exec_as_root umount -l $ROOTFS_DIR &> /dev/null || true; \
echo \"Cleaning up containers:\"; \
docker container rm -f $CONTAINER_ID $MOUNT_CONTAINER_ID" EXIT

# Extract image
echo "Extracting docker image"
docker container export -o $BUILD_DIR/filesystem.tar $CONTAINER_ID
exec_as_root tar -xf $BUILD_DIR/filesystem.tar -C $ROOTFS_DIR > /dev/null

# Avoid detecting as container
echo "Removing .dockerenv file"
exec_as_root rm -f $ROOTFS_DIR/.dockerenv

echo "Setting network stuff"
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
  bash -c "printf \"$GIT_HASH\n$DATETIME\" > BUILD"
}
GIT_HASH=${GIT_HASH:-$(git --git-dir=$DIR/.git rev-parse HEAD)}
exec_as_root bash -c "set -e; export ROOTFS_DIR=$ROOTFS_DIR GIT_HASH=$GIT_HASH; $(declare -f set_network_stuff); set_network_stuff"

# Unmount image
echo "Unmount filesystem"
exec_as_root umount -l $ROOTFS_DIR

# Copy system image to output
cp $ROOTFS_IMAGE $OUT_IMAGE

echo "Done!"
