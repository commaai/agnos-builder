#!/usr/bin/env bash
set -e

git lfs &> /dev/null || {
  echo "ERROR: git lfs not installed"
  exit 1
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
THIS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT=$DIR/..

cd $DIR

# grep for `-`, which stands for LFS pointer
git lfs ls-files | awk '{print $2}' | grep "-" &>/dev/null && {
  echo "Pulling git lfs objects..."
  cd $ROOT
  git lfs install
  git lfs pull
  cd $DIR
}

LINARO_GCC=aarch64-linux-gnu-gcc
GOOGLE_GCC_4_9=aarch64-linux-android-4.9
EDK2_LLVM=llvm-arm-toolchain-ship
SEC_IMAGE=SecImage

LINARO_GCC_TARBALL=$LINARO_GCC.tar.gz
GOOGLE_GCC_4_9_TARBALL=$GOOGLE_GCC_4_9.tar.gz
EDK2_LLVM_TARBALL=$EDK2_LLVM.tar.gz
SEC_IMAGE_TARBALL=$SEC_IMAGE.tar.gz

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "aarch64" ]; then
  echo "Extracting tools..."
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
fi
