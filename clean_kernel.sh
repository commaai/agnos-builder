#!/bin/bash -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
KERNEL_DIR=$DIR/kernel/linux

cd $KERNEL_DIR

make $DEFCONFIG O=out mrproper
rm -rf out
rm *.deb *.buildinfo *.changes
