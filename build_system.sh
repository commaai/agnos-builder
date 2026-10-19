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

# Setup qemu multiarch, not needed for remote arm64 builds
if [ "$(uname -m)" = "x86_64" ] && [ -z "$NS" ]; then
  echo "Registering emulator"
  docker run --rm --privileged tonistiigi/binfmt --install all
fi

# Check agnos-builder Dockerfile
export DOCKER_BUILDKIT=1
docker buildx build -f Dockerfile.agnos --check $DIR

# Build the system image in docker, only the sparse image is exported
echo "Building system image"
BUILD="docker buildx build --output type=local,dest=$BUILD_DIR/image"
if [ ! -z "$NS" ]; then
  if ! command -v zstd &> /dev/null; then
    echo "zstd missing, please install it"
    exit 1
  fi
  BUILD="nsc build --region ${NS_REGION:-us} --output-local $BUILD_DIR/image --build-arg ZSTD=1"
fi
GIT_HASH=${GIT_HASH:-$(git --git-dir=$DIR/.git rev-parse HEAD)}
rm -rf $BUILD_DIR/image
$BUILD -f Dockerfile.agnos $DIR --platform=linux/arm64 \
  --build-arg UBUNTU_BASE_IMAGE=$UBUNTU_FILE \
  --build-arg GIT_HASH=$GIT_HASH \
  --build-arg BUILD_DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
if [ -f $BUILD_DIR/image/system.img.zst ]; then
  zstd -q -d -f $BUILD_DIR/image/system.img.zst -o $OUT_IMAGE
else
  mv $BUILD_DIR/image/system.img $OUT_IMAGE
fi
rm -rf $BUILD_DIR/image

echo "Done!"
