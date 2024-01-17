#!/bin/bash
set -e

UBUNTU_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/daily/current"
UBUNTU_FILE="noble-base-arm64.tar.gz"

export DOCKER_BUILDKIT=1

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

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
  wget -c $UBUNTU_BASE_URL/$UBUNTU_FILE --quiet
fi

# Register qemu multiarch
if [ "$(uname -p)" != "aarch64" ]; then
  docker run --rm --privileged multiarch/qemu-user-static:register --reset
fi

# Start docker build
echo "Building image"
export DOCKER_CLI_EXPERIMENTAL=enabled
docker build -f Dockerfile.agnos -t agnos-builder $DIR
# docker build -f Dockerfile.agnos -t agnos-compiler-capnp --target agnos-compiler-capnp $DIR
# docker build -f Dockerfile.agnos -t agnos-compiler-mapbox-gl-native --target agnos-compiler-mapbox-gl-native $DIR
# docker build -f Dockerfile.agnos -t agnos-compiler-ffmpeg --target agnos-compiler-ffmpeg $DIR
# exit 0

# Create filesystem ext4 image
echo "Creating empty filesystem"
fallocate -l $ROOTFS_IMAGE_SIZE $ROOTFS_IMAGE
mkfs.ext4 $ROOTFS_IMAGE > /dev/null

# Mount filesystem
echo "Mounting empty filesystem"
mkdir -p $ROOTFS_DIR
sudo umount -l $ROOTFS_DIR > /dev/null || true
sudo mount $ROOTFS_IMAGE $ROOTFS_DIR

# Extract image
echo "Extracting docker image"
CONTAINER_ID=$(docker container create --entrypoint /bin/bash agnos-builder:latest)
docker container export -o $BUILD_DIR/filesystem.tar $CONTAINER_ID
docker container rm $CONTAINER_ID > /dev/null
cd $ROOTFS_DIR
sudo tar -xf $BUILD_DIR/filesystem.tar > /dev/null

# Add hostname and hosts. This cannot be done in the docker container...
echo "Setting network stuff"
HOST=comma
sudo bash -c "ln -sf /proc/sys/kernel/hostname etc/hostname"
sudo bash -c "echo \"127.0.0.1    localhost.localdomain localhost\" > etc/hosts"
sudo bash -c "echo \"127.0.0.1    $HOST\" >> etc/hosts"

# Fix resolv config
sudo bash -c "ln -sf /run/systemd/resolve/stub-resolv.conf etc/resolv.conf"

# Write build info
DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
GIT_HASH=$(git --git-dir=$DIR/.git rev-parse HEAD)
sudo bash -c "printf \"$GIT_HASH\n$DATETIME\" > BUILD"

cd $DIR

# Unmount image
echo "Unmount filesystem"
sudo umount -l $ROOTFS_DIR

# Sparsify
echo "Sparsify image"
TMP_SPARSE="$(mktemp)"
img2simg $ROOTFS_IMAGE $TMP_SPARSE
mv $TMP_SPARSE $SPARSE_IMAGE

# Make image with skipped chunks
TMP_SKIP="$(mktemp)"
$DIR/tools/simg2dontcare.py $SPARSE_IMAGE $TMP_SKIP
mv $TMP_SKIP $SKIP_CHUNKS_IMAGE

echo "Done!"
