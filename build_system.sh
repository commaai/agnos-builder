#!/bin/bash
set -e

UBUNTU_BASE_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release"
UBUNTU_FILE="ubuntu-base-20.04.1-base-arm64.tar.gz"

# TODO: remove in another PR
export DOCKER_BUILDKIT=1 # default from v23.0 and later
export DOCKER_CLI_EXPERIMENTAL=enabled # deprecated since v19.03

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

ARCH=$(uname -m)

BUILD_DIR="$DIR/build"
OUTPUT_DIR="$DIR/output"

ROOTFS_DIR="$BUILD_DIR/agnos-rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system.img.raw"
ROOTFS_IMAGE_SIZE=10G
SPARSE_IMAGE="$OUTPUT_DIR/system.img"
SKIP_CHUNKS_IMAGE="$OUTPUT_DIR/system-skip-chunks.img"

# Create temp dir if non-existent
mkdir -p $BUILD_DIR $OUTPUT_DIR

# Copy kernel modules over
if ! ls $OUTPUT_DIR/*.ko >/dev/null 2>&1; then
  echo "kernel modules missing. run ./build_kernel.sh first"
  exit 1
fi
cp $OUTPUT_DIR/wlan.ko $DIR/userspace/usr/comma
cp $OUTPUT_DIR/snd*.ko $DIR/userspace/usr/comma/sound/

# Download Ubuntu Base if not done already
if [ ! -f $UBUNTU_FILE ]; then
  echo -e "${GREEN}Downloading Ubuntu: $UBUNTU_FILE ${NO_COLOR}"
  curl -C - -o $UBUNTU_FILE $UBUNTU_BASE_URL/$UBUNTU_FILE --silent
fi

# Register qemu multiarch
if [ "$ARCH" = "x86_64" ]; then
  echo "Registering qemu-user-static"
  docker run --rm --privileged multiarch/qemu-user-static:register --reset > /dev/null
fi

# Start agnos-builder docker build and create container
echo "Building agnos-builder docker image"
docker build -f Dockerfile.agnos -t agnos-builder $DIR
echo "Creating agnos-builder container"
CONTAINER_ID=$(docker container create --entrypoint /bin/bash agnos-builder:latest)

# Setup mount container for macOS and CI support (namespace.so)
if ! docker inspect agnos-mount &>/dev/null; then
  echo "Building agnos-mount docker image"
  docker build -f Dockerfile.sparsify -t agnos-mount $DIR
fi
echo "Starting agnos-mount container"
MOUNT_CONTAINER_ID=$(docker run -d --privileged -v $DIR:$DIR agnos-mount)

# Cleanup containers on possible exit
trap "echo \"Cleaning up containers:\"; \
docker container rm -f $CONTAINER_ID $MOUNT_CONTAINER_ID" EXIT

# Create host user in container (fixes namespace.so error)
USERNAME=$(whoami)
docker exec $MOUNT_CONTAINER_ID bash -c "useradd --uid $(id -u) -U -m $USERNAME" &> /dev/null

# Create filesystem ext4 image
echo "Creating empty filesystem"
docker exec -u $USERNAME $MOUNT_CONTAINER_ID fallocate -l $ROOTFS_IMAGE_SIZE $ROOTFS_IMAGE
docker exec -u $USERNAME $MOUNT_CONTAINER_ID mkfs.ext4 $ROOTFS_IMAGE &> /dev/null

# Mount filesystem
echo "Mounting empty filesystem"
docker exec $MOUNT_CONTAINER_ID mkdir -p $ROOTFS_DIR
docker exec $MOUNT_CONTAINER_ID mount $ROOTFS_IMAGE $ROOTFS_DIR

# Also unmount filesystem (overwrite previous trap)
trap "docker exec $MOUNT_CONTAINER_ID umount -l $ROOTFS_DIR &> /dev/null || true; \
echo \"Cleaning up containers:\"; \
docker container rm -f $CONTAINER_ID $MOUNT_CONTAINER_ID" EXIT

# Extract image
echo "Extracting docker image"
docker container export -o $BUILD_DIR/filesystem.tar $CONTAINER_ID
docker exec $MOUNT_CONTAINER_ID tar -xf $BUILD_DIR/filesystem.tar -C $ROOTFS_DIR > /dev/null

# Add hostname and hosts. This cannot be done in the docker container...
echo "Setting network stuff"
HOST=comma
docker exec -w $ROOTFS_DIR $MOUNT_CONTAINER_ID bash -c "\
ln -sf /proc/sys/kernel/hostname etc/hostname; \
echo \"127.0.0.1    localhost.localdomain localhost\" > etc/hosts; \
echo \"127.0.0.1    $HOST\" >> etc/hosts"

# Fix resolv config
docker exec -w $ROOTFS_DIR $MOUNT_CONTAINER_ID bash -c "ln -sf /run/systemd/resolve/stub-resolv.conf etc/resolv.conf"

# Write build info
DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
GIT_HASH=$(git --git-dir=$DIR/.git rev-parse HEAD)
docker exec -w $ROOTFS_DIR $MOUNT_CONTAINER_ID bash -c "printf \"$GIT_HASH\n$DATETIME\" > BUILD"

# Unmount image
echo "Unmount filesystem"
docker exec $MOUNT_CONTAINER_ID umount -l $ROOTFS_DIR

# Sparsify
echo "Sparsify image $(basename $SPARSE_IMAGE)"
docker exec -u $USERNAME $MOUNT_CONTAINER_ID bash -c "\
TMP_SPARSE=\$(mktemp); \
img2simg $ROOTFS_IMAGE \$TMP_SPARSE; \
mv \$TMP_SPARSE $SPARSE_IMAGE"

# Make image with skipped chunks
echo "Sparsify image $(basename $SKIP_CHUNKS_IMAGE)"
docker exec -u $USERNAME $MOUNT_CONTAINER_ID bash -c "\
TMP_SKIP=\$(mktemp); \
$DIR/tools/simg2dontcare.py $SPARSE_IMAGE \$TMP_SKIP; \
mv \$TMP_SKIP $SKIP_CHUNKS_IMAGE"

echo "Done!"
