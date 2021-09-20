#!/bin/bash -e

echo "Extracting tools..."

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
THIS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT=$DIR/..

cd $DIR

LINARO_GCC=aarch64-linux-gnu-gcc
GOOGLE_GCC_4_9=aarch64-linux-android-4.9
EDK2_LLVM=llvm-arm-toolchain-ship
SEC_IMAGE=SecImage

if [ ! -f $LINARO_GCC*.gz ] || \
   [ ! -f $GOOGLE_GCC_4_9*.gz ] || \
   [ ! -f $EDK2_LLVM*.gz ] || \
   [ ! -f $SEC_IMAGE*.gz ]; then
  cd $ROOT
  git lfs install
  git lfs pull
  cd $DIR
fi

LINARO_GCC_TARBALL=$LINARO_GCC.tar.gz
GOOGLE_GCC_4_9_TARBALL=$GOOGLE_GCC_4_9.tar.gz
EDK2_LLVM_TARBALL=$EDK2_LLVM.tar.gz
SEC_IMAGE_TARBALL=$SEC_IMAGE.tar.gz

if [ ! -d $LINARO_GCC ]; then
  tar -xzf $LINARO_GCC_TARBALL &>/dev/null
fi

if [ ! -d $GOOGLE_GCC_4_9 ]; then
  tar -xzf $GOOGLE_GCC_4_9_TARBALL &>/dev/null
fi

if [ ! -d $EDK2_LLVM ]; then
  tar -xzf $EDK2_LLVM_TARBALL &>/dev/null
fi

if [ ! -d $SEC_IMAGE ]; then
  tar -xzf $SEC_IMAGE_TARBALL &>/dev/null
fi
