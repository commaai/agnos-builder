#!/usr/bin/env bash
set -e

UBUNTU_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/"
UBUNTU_FILE="ubuntu-base-24.04.3-base-arm64.tar.gz"
UBUNTU_FILE_CHECKSUM="7b2dced6dd56ad5e4a813fa25c8de307b655fdabc6ea9213175a92c48dabb048"

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

OUTPUT_DIR="$DIR/output"

# the partition is 10G, but openpilot's updater didn't always handle the full size
# openpilot fix, shipped in 0.9.8 (8/18/24): https://github.com/commaai/openpilot/pull/33320
ROOTFS_IMAGE_SIZE=4500M

# Create output dir if non-existent
mkdir -p $OUTPUT_DIR

# Download Ubuntu Base if not done already
if [ ! -f $UBUNTU_FILE ]; then
  echo "Downloading Ubuntu Base: $UBUNTU_FILE"
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

# Check Dockerfile syntax
export DOCKER_BUILDKIT=1
docker buildx build -f Dockerfile.agnos --check $DIR

# Get git hash for build info
GIT_HASH=${GIT_HASH:-$(git --git-dir=$DIR/.git rev-parse HEAD)}

# Build with nsc and extract system.img directly
echo "Building with nsc"
nsc build -f Dockerfile.agnos \
  --output-local "$OUTPUT_DIR" \
  --build-arg UBUNTU_BASE_IMAGE="$UBUNTU_FILE" \
  --build-arg GIT_HASH="$GIT_HASH" \
  --build-arg ROOTFS_IMAGE_SIZE="$ROOTFS_IMAGE_SIZE" \
  --platform=linux/arm64 \
  "$DIR"

echo "Done!"
