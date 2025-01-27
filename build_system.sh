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
OUT_IMAGE="$OUTPUT_DIR/system.img"

# Create temp dir if non-existent
mkdir -p $BUILD_DIR $OUTPUT_DIR

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
BUILD="docker buildx build --load"
if [ ! -z "$NS" ]; then
  BUILD="nsc build --load"
fi
$BUILD -f Dockerfile.agnos -t agnos-builder $DIR --build-arg UBUNTU_BASE_IMAGE=$UBUNTU_FILE --platform=linux/arm64
echo "Creating agnos-builder container"
CONTAINER_ID=$(docker container create --entrypoint /bin/bash agnos-builder:latest)

# Check agnos-meta-builder Dockerfile
docker buildx build --load -f Dockerfile.builder --check $DIR \
  --build-arg UNAME=$(id -nu) \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g)

# Setup mount container for macOS and CI support (namespace.so)
echo "Building agnos-meta-builder docker image"
docker buildx build --load -f Dockerfile.builder -t agnos-meta-builder $DIR \
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

# Mount filesystem
echo "Mounting empty filesystem"
exec_as_root mkdir -p $ROOTFS_DIR

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
  bash -c "printf \"$GIT_HASH\n$DATETIME\n\" > BUILD"
}
GIT_HASH=${GIT_HASH:-$(git --git-dir=$DIR/.git rev-parse HEAD)}
exec_as_root bash -c "set -e; export ROOTFS_DIR=$ROOTFS_DIR GIT_HASH=$GIT_HASH; $(declare -f set_network_stuff); set_network_stuff"

echo "Creating final squashfs image"
rm -f $OUT_IMAGE
# TODO: probably possible to do some more tuning here
exec_as_root mksquashfs $ROOTFS_DIR $OUT_IMAGE -comp lzo -b 1M -no-xattrs

echo "Done!"
