#!/usr/bin/env bash
set -e

DEFCONFIG=tici_defconfig

# Get directories and make sure we're in the correct spot to start the build
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
TOOLS=$DIR/tools
TMP_DIR=/tmp/agnos-builder-tmp
OUTPUT_DIR=$DIR/output
BOOT_IMG=./boot.img
cd $DIR

# Clone kernel if not done already
if [ ! -d agnos-kernel-sdm845 ]; then
  git submodule init agnos-kernel-sdm845
fi
cd agnos-kernel-sdm845

# Build parameters
export ARCH=arm64
if [ ! -f /TICI ]; then
  export CROSS_COMPILE=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-
  export CC=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-gcc
  export LD=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-ld.bfd
fi

# these do anything?
export KCFLAGS="-w"

# Load defconfig and build kernel
echo "-- First make --"
make $DEFCONFIG O=out
echo "-- Second make: $(nproc --all) cores --"
ARGS=""
if [ -f /TICI ]; then
  ARGS="sudo -E"
fi
$ARGS make bindeb-pkg -j$(nproc --all) O=out  # Image.gz-dtb

# Copy output
mkdir -p $OUTPUT_DIR
cp linux-headers-*.deb $OUTPUT_DIR

