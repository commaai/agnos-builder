#!/bin/bash -e

UBUNTU_BASE_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release"
UBUNTU_FILE="ubuntu-base-20.04.1-base-arm64.tar.gz"

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

BUILD_DIR="$DIR/build"
OUTPUT_DIR="$DIR/output"

ROOTFS_DIR="$BUILD_DIR/agnos-rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system.img.raw"
ROOTFS_IMAGE_SIZE=10G
SPARSE_IMAGE="$BUILD_DIR/system.img"

# Create temp dir if non-existent
mkdir -p $BUILD_DIR $OUTPUT_DIR

# Download Ubuntu Base if not done already
if [ ! -f $UBUNTU_FILE ]; then
  echo -e "${GREEN}Downloading Ubuntu: $UBUNTU_FILE ${NO_COLOR}"
  wget -c $UBUNTU_BASE_URL/$UBUNTU_FILE --quiet
fi

# TODO: this needs to be re-done sometimes
# Register qemu multiarch if not done
if [ ! -f $DIR/.qemu_registered ] && [ "$(uname -p)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
  docker run --rm --privileged multiarch/qemu-user-static:register
  touch $DIR/.qemu_registered
fi

# Start docker build
echo "Building image"
export DOCKER_CLI_EXPERIMENTAL=enabled
docker build -f Dockerfile.agnos -t agnos-builder $DIR

# Create a temporary container in which to do some platform-specific work so that Mac can build too
docker start build_system_helper || docker run -d \
  --privileged \
  --mount type=bind,source=$BUILD_DIR,target=$BUILD_DIR \
  --mount type=bind,source=/tmp/script.sh,target=/tmp/script.sh \
  --name build_system_helper \
  -t ubuntu:20.04 bash

docker exec -t build_system_helper apt update
docker exec -t build_system_helper apt install -y img2simg

# Create filesystem ext4 image
echo "Creating empty filesystem"
docker exec -t build_system_helper fallocate -l $ROOTFS_IMAGE_SIZE $ROOTFS_IMAGE
docker exec -it build_system_helper mkfs.ext4 $ROOTFS_IMAGE

# Mount filesystem
echo "Mounting empty filesystem"
mkdir -p $ROOTFS_DIR
docker exec -t build_system_helper umount -l $ROOTFS_DIR || true
docker exec -t build_system_helper mount $ROOTFS_IMAGE $ROOTFS_DIR

# Extract image
echo "Extracting docker image"
CONTAINER_ID=$(docker container create --entrypoint /bin/bash agnos-builder:latest)
docker container export -o $BUILD_DIR/filesystem.tar $CONTAINER_ID
docker container rm $CONTAINER_ID > /dev/null
cd $ROOTFS_DIR
sudo tar -xf $BUILD_DIR/filesystem.tar > /dev/null

# Add hostname and hosts. This cannot be done in the docker container...
echo "Setting network stuff"
HOST=tici
sudo bash -c "echo $HOST > etc/hostname"
sudo bash -c "echo \"127.0.0.1    localhost.localdomain localhost\" > etc/hosts"
sudo bash -c "echo \"127.0.0.1    $HOST\" >> etc/hosts"

# Fix resolv config
sudo bash -c "ln -sf /run/systemd/resolve/stub-resolv.conf etc/resolv.conf"

cd $DIR

# Unmount image
echo "Unmount filesystem"
docker exec -it build_system_helper umount -l $ROOTFS_DIR

# Sparsify
echo "Sparsify image"
docker exec -it build_system_helper img2simg $ROOTFS_IMAGE $SPARSE_IMAGE
mv $SPARSE_IMAGE $OUTPUT_DIR

# Remove the temporary container
docker rm -f build_system_helper

echo "Done!"
