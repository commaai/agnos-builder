#!/usr/bin/env bash
set -euo pipefail

ALPINE_VERSION="${ALPINE_VERSION:-3.20.8}"
ALPINE_SERIES="$(echo "$ALPINE_VERSION" | awk -F. '{printf "%s.%s", $1, $2}')"
ALPINE_BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_SERIES}/releases/aarch64"
ALPINE_FILE="alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
ALPINE_FILE_CHECKSUM="${ALPINE_FILE_CHECKSUM:-6d0e15d9f9f5c5003c4692337dffebe9475cab7d8a0390f109f6999fbb28745f}"

# Ensure we are inside the repo root
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd "$DIR"

BUILD_DIR="$DIR/build/alpine"
OUTPUT_DIR="$DIR/output/alpine"

ROOTFS_DIR="$BUILD_DIR/rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system-alpine.img"
OUT_IMAGE="$OUTPUT_DIR/system-alpine.img"

ROOTFS_IMAGE_SIZE="${ROOTFS_IMAGE_SIZE:-2048M}"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Download Alpine minirootfs if missing
if [ ! -f "$ALPINE_FILE" ]; then
  echo "Downloading Alpine minirootfs: $ALPINE_FILE"
  if ! curl -C - -o "$ALPINE_FILE" "$ALPINE_BASE_URL/$ALPINE_FILE" --silent --remote-time --fail; then
    echo "Download failed, please check Alpine releases: $ALPINE_BASE_URL"
    exit 1
  fi
fi

# Verify checksum
if [ "$(shasum -a 256 "$ALPINE_FILE" | awk '{print $1}')" != "$ALPINE_FILE_CHECKSUM" ]; then
  echo "Checksum mismatch, please check Alpine releases: $ALPINE_BASE_URL"
  exit 1
fi

# Register qemu user emulation if needed
if [ "$(uname -m)" = "x86_64" ]; then
  echo "Registering qemu-user-static"
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes > /dev/null
fi

export DOCKER_BUILDKIT=1

echo "Checking Dockerfile.alpine"
docker buildx build -f Dockerfile.alpine --check "$DIR" \
  --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
  --build-arg ALPINE_BASE_IMAGE="$ALPINE_FILE"

echo "Building Alpine system image"
BUILD_CMD="docker buildx build --load"
if [ -n "${NS:-}" ]; then
  BUILD_CMD="nsc build --load"
fi
$BUILD_CMD -f Dockerfile.alpine -t agnos-alpine "$DIR" \
  --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
  --build-arg ALPINE_BASE_IMAGE="$ALPINE_FILE" \
  --platform=linux/arm64

echo "Creating agnos-alpine container"
CONTAINER_ID=$(docker container create --entrypoint /bin/sh agnos-alpine:latest)

echo "Checking meta-builder Dockerfile"
docker buildx build --load -f Dockerfile.builder --check "$DIR" \
  --build-arg UNAME="$(id -nu)" \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)"

echo "Building meta-builder"
docker buildx build --load -f Dockerfile.builder -t agnos-meta-builder "$DIR" \
  --build-arg UNAME="$(id -nu)" \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)"

echo "Starting meta-builder container"
MOUNT_CONTAINER_ID=$(docker run -d --privileged -v "$DIR:$DIR" agnos-meta-builder)

cleanup() {
  echo "Cleaning up containers:"
  docker container rm -f "$CONTAINER_ID" "$MOUNT_CONTAINER_ID" > /dev/null
}
trap cleanup EXIT

exec_as_user() {
  docker exec -u "$(id -nu)" "$MOUNT_CONTAINER_ID" "$@"
}

exec_as_root() {
  docker exec "$MOUNT_CONTAINER_ID" "$@"
}

echo "Creating sparse filesystem"
exec_as_user mkdir -p "$BUILD_DIR"
exec_as_user fallocate -l "$ROOTFS_IMAGE_SIZE" "$ROOTFS_IMAGE"
exec_as_user mkfs.ext4 "$ROOTFS_IMAGE" > /dev/null

echo "Mounting filesystem"
exec_as_root mkdir -p "$ROOTFS_DIR"
exec_as_root mount "$ROOTFS_IMAGE" "$ROOTFS_DIR"

cleanup_with_umount() {
  exec_as_root umount -l "$ROOTFS_DIR" > /dev/null 2>&1 || true
  cleanup
}
trap cleanup_with_umount EXIT

echo "Extracting container filesystem"
docker container export -o "$BUILD_DIR/filesystem.tar" "$CONTAINER_ID"
exec_as_root tar -xf "$BUILD_DIR/filesystem.tar" -C "$ROOTFS_DIR" > /dev/null

echo "Removing container markers"
exec_as_root rm -f "$ROOTFS_DIR/.dockerenv"

echo "Configuring hostname and networking files"
set_network_stuff() {
  cd "$ROOTFS_DIR"
  HOST=comma
  ln -sf /proc/sys/kernel/hostname etc/hostname
  echo "127.0.0.1    localhost.localdomain localhost" > etc/hosts
  echo "127.0.0.1    $HOST" >> etc/hosts
  ln -sf /run/network/resolv.conf etc/resolv.conf
  DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
  printf "%s\n%s\n" "$GIT_HASH" "$DATETIME" > BUILD
}
GIT_HASH=${GIT_HASH:-$(git --git-dir="$DIR/.git" rev-parse HEAD)}
exec_as_root bash -c "set -e; export ROOTFS_DIR=\"$ROOTFS_DIR\" GIT_HASH=\"$GIT_HASH\"; $(declare -f set_network_stuff); set_network_stuff"

echo "Unmounting filesystem"
exec_as_root umount -l "$ROOTFS_DIR"

echo "Sparsifying image"
exec_as_user img2simg "$ROOTFS_IMAGE" "$OUT_IMAGE"

echo "Alpine image written to $OUT_IMAGE"
