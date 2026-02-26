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

# the partition is 10G, but openpilot's updater didn't always handle the full size
# openpilot fix, shipped in 0.9.8 (8/18/24): https://github.com/commaai/openpilot/pull/33320
ROOTFS_IMAGE_SIZE=4500M

# Create temp dir if non-existent
mkdir -p $BUILD_DIR $OUTPUT_DIR

# Download Ubuntu Base if not done already (optimized with parallel execution)
download_ubuntu() {
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
}

# Setup qemu multiarch
setup_qemu() {
  if [ "$(uname -m)" = "x86_64" ]; then
    echo "Registering emulator"
    docker run --rm --privileged tonistiigi/binfmt --install all
  fi
}

# Parallel setup
download_ubuntu &
setup_qemu &
wait  # Wait for both background jobs

# Check agnos-builder Dockerfile
export DOCKER_BUILDKIT=1
docker buildx build -f Dockerfile.agnos.optimized --check $DIR

# Parallel Docker builds
echo "Building Docker images in parallel"
BUILD="docker buildx build --load"
if [ ! -z "$NS" ]; then
  BUILD="nsc build --load"
fi

# Build agnos-builder in background
echo "Starting agnos-builder docker build"
(
  $BUILD -f Dockerfile.agnos.optimized -t agnos-builder $DIR --build-arg UBUNTU_BASE_IMAGE=$UBUNTU_FILE --platform=linux/arm64
  echo "agnos-builder build completed"
) &
AGNOS_BUILD_PID=$!

# Build agnos-meta-builder in parallel
echo "Starting agnos-meta-builder docker build"
(
  docker buildx build --load -f Dockerfile.builder --check $DIR \
    --build-arg UNAME=$(id -nu) \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g) > /dev/null

  docker buildx build --load -f Dockerfile.builder -t agnos-meta-builder $DIR \
    --build-arg UNAME=$(id -nu) \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g)
  echo "agnos-meta-builder build completed"
) &
BUILDER_BUILD_PID=$!

# Wait for agnos-builder to complete first (needed for container creation)
echo "Waiting for agnos-builder to complete..."
wait $AGNOS_BUILD_PID

echo "Creating agnos-builder container"
CONTAINER_ID=$(docker container create --entrypoint /bin/bash agnos-builder:latest)

# Wait for agnos-meta-builder to complete
echo "Waiting for agnos-meta-builder to complete..."
wait $BUILDER_BUILD_PID

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

# Parallel filesystem operations
echo "Creating and extracting filesystem in parallel"

# Create and mount filesystem
(
  echo "Creating empty filesystem"
  exec_as_user fallocate -l $ROOTFS_IMAGE_SIZE $ROOTFS_IMAGE
  exec_as_user mkfs.ext4 $ROOTFS_IMAGE &> /dev/null
  echo "Mounting empty filesystem"
  exec_as_root mkdir -p $ROOTFS_DIR
  exec_as_root mount $ROOTFS_IMAGE $ROOTFS_DIR
) &
FILESYSTEM_PID=$!

# Extract docker image (can start immediately)
echo "Extracting docker image"
docker container export $CONTAINER_ID | gzip > $BUILD_DIR/filesystem.tar.gz &
EXTRACT_PID=$!

# Wait for filesystem to be ready
wait $FILESYSTEM_PID

# Also unmount filesystem (overwrite previous trap)
trap "exec_as_root umount -l $ROOTFS_DIR &> /dev/null || true; \
echo \"Cleaning up containers:\"; \
docker container rm -f $CONTAINER_ID $MOUNT_CONTAINER_ID" EXIT

# Wait for extraction and decompress directly to filesystem
wait $EXTRACT_PID
echo "Extracting to filesystem"
exec_as_root gzip -dc $BUILD_DIR/filesystem.tar.gz | exec_as_root tar -xf - -C $ROOTFS_DIR > /dev/null

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

# Unmount and finalize in parallel
echo "Finalizing image"
(
  echo "Unmount filesystem"
  exec_as_root umount -l $ROOTFS_DIR
  
  # Sparsify system image
  exec_as_user img2simg $ROOTFS_IMAGE $OUT_IMAGE
) &

# Clean up temporary files in parallel
(
  echo "Cleaning up temporary files"
  rm -f $BUILD_DIR/filesystem.tar.gz
) &

wait  # Wait for all background operations

echo "Done!"