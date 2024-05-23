#!/bin/bash
set -e

DEFCONFIG="defconfig comma3.config"

# Get directories and make sure we're in the correct spot to start the build
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ARCH=$(uname -m)
TOOLS=$DIR/tools
TMP_DIR=/tmp/agnos-builder-new-kernel-tmp
OUTPUT_DIR=$DIR/output
BOOT_IMG=./boot.img
KERNEL_DIR=$DIR/kernel/linux

cd $KERNEL_DIR

if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "aarch64" ]; then
  # Build parameters
  export ARCH=arm64
  export CROSS_COMPILE=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-
  export CC=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-gcc
  export LD=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-ld.bfd
fi

rm -f *.deb *.buildinfo *.changes

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
$ARGS make bindeb-pkg -j$(nproc --all) O=out

# Copy output
mkdir -p $OUTPUT_DIR
rm $OUTPUT_DIR/linux-*.deb
cp *.deb $OUTPUT_DIR
