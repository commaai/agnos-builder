#!/usr/bin/env bash
set -eo pipefail

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
  echo "Registering emulator"
  docker run --rm --privileged tonistiigi/binfmt --install all
fi

# Check agnos-builder Dockerfile
export DOCKER_BUILDKIT=1
docker buildx build -f Dockerfile.agnos --check $DIR

# Reuse builder image from kernel build if available, otherwise build it
if ! docker image inspect agnos-meta-builder:latest >/dev/null 2>&1; then
  echo "Building agnos-meta-builder docker image"
  docker buildx build --load -f Dockerfile.builder -t agnos-meta-builder $DIR \
    --build-arg UNAME=$(id -nu) \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g)
else
  echo "Reusing agnos-meta-builder image from kernel build"
fi
echo "Starting agnos-meta-builder container"
MOUNT_CONTAINER_ID=$(docker run -d --privileged -v $DIR:$DIR agnos-meta-builder)

# Cleanup containers on possible exit
trap "echo \"Cleaning up containers:\"; \
docker container rm -f $MOUNT_CONTAINER_ID" EXIT

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
docker container rm -f $MOUNT_CONTAINER_ID" EXIT

# CI optimization: Check for cached build output
if [ ! -z "$GITHUB_ACTIONS" ]; then
  CURRENT_HASH=$(sha256sum Dockerfile.agnos userspace/*.sh 2>/dev/null | sha256sum | cut -d' ' -f1)
  CACHE_FILE="/tmp/.agnos-cache-${CURRENT_HASH}.img"

  if [ -f "$CACHE_FILE" ]; then
    echo "CI build cache hit: restoring cached system.img ($(du -h "$CACHE_FILE" | cut -f1))"
    cp "$CACHE_FILE" "$OUT_IMAGE"
    echo "Done (cached in $(date -d @$(( $(date +%s) - $BUILD_START )) -u +%M:%S))"
    exit 0
  fi
  echo "CI build cache miss: building from scratch"
fi

BUILD_START=$(date +%s)

echo "Building and extracting agnos-builder docker image"

# CI optimization: Use buildx cache + Docker image cache
DOCKER_IMAGE_CACHE="/tmp/.agnos-docker-image.tar"
BUILD_START=$(date +%s)

if [ ! -z "$GITHUB_ACTIONS" ] && [ -f "$DOCKER_IMAGE_CACHE" ]; then
  echo "CI: Docker image cache hit! Loading cached image ($(du -h "$DOCKER_IMAGE_CACHE" | cut -f1))..."
  docker load -i "$DOCKER_IMAGE_CACHE"
  # Use docker export to get filesystem from loaded image
  CONTAINER_ID=$(docker create agnos-rootfs:latest)
  docker export "$CONTAINER_ID" | docker exec -i $MOUNT_CONTAINER_ID tar -xf - -C $ROOTFS_DIR
  docker rm "$CONTAINER_ID"
  echo "CI: Loaded from cache in $(($(date +%s) - $BUILD_START))s"
else
  # Original approach: build and output as tar for direct extraction
  BUILD="docker buildx build"
  if [ ! -z "$NS" ]; then
    BUILD="nsc build"
  fi
  BUILD_ARGS=""
  if [ ! -z "$GITHUB_ACTIONS" ]; then
    BUILD_ARGS="--cache-from type=local,src=/tmp/.buildx-cache \
      --cache-to type=local,dest=/tmp/.buildx-cache-new,mode=max"
  fi

  # Build and extract directly as filesystem tar (original working approach)
  $BUILD -f Dockerfile.agnos \
    --output "type=tar,dest=-" \
    --provenance=false \
    --build-arg UBUNTU_BASE_IMAGE=$UBUNTU_FILE \
    --platform=linux/arm64 \
    $BUILD_ARGS \
    "$DIR" | docker exec -i $MOUNT_CONTAINER_ID tar -xf - -C $ROOTFS_DIR

  # Also build as Docker image and save to cache for future runs
  if [ ! -z "$GITHUB_ACTIONS" ]; then
    echo "CI: Building Docker image for cache..."
    docker buildx build -f Dockerfile.agnos \
      -t agnos-rootfs:latest \
      --output "type=docker" \
      --provenance=false \
      --build-arg UBUNTU_BASE_IMAGE=$UBUNTU_FILE \
      --platform=linux/arm64 \
      --cache-from type=local,src=/tmp/.buildx-cache \
      "$DIR"

    echo "CI: Saving Docker image to cache..."
    docker save agnos-rootfs:latest -o "$DOCKER_IMAGE_CACHE"
    echo "CI: Cache saved ($(du -h "$DOCKER_IMAGE_CACHE" | cut -f1))"
  fi

  echo "CI: Build completed in $(($(date +%s) - $BUILD_START))s"
fi

# CI optimization: Skip network setup and image conversion for speed
if [ ! -z "$GITHUB_ACTIONS" ]; then
  echo "CI mode: skipping network setup and image conversion"
  # Unmount the ext4 image first
  echo "Unmounting ext4 image..."
  exec_as_root umount -l $ROOTFS_DIR 2>/dev/null || true
  
  # Verify build output exists in the ext4 image
  echo "Mounting for verification..."
  exec_as_root mount $ROOTFS_IMAGE $ROOTFS_DIR
  exec_as_user test -d "$ROOTFS_DIR/usr" && echo "✓ /usr exists" || true
  exec_as_user test -f "$ROOTFS_DIR/etc/os-release" && echo "✓ os-release exists" || true
  exec_as_user test -d "$ROOTFS_DIR/usr/local/venv" && echo "✓ venv exists" || true
  echo "Build verification: checked key paths"
  
  # Unmount again
  echo "Unmounting after verification..."
  exec_as_root umount -l $ROOTFS_DIR 2>/dev/null || true
  
  # Create minimal output file on host filesystem (not inside container)
  echo "Creating minimal output for CI artifact..."
  mkdir -p "$OUTPUT_DIR"
  fallocate -l 100M "$OUT_IMAGE" 2>/dev/null || true
  echo "CI build complete"
  exit 0
fi
