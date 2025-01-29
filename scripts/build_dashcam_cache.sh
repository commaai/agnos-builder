#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
OUTPUT_DIR=$DIR/../output
GIT_BRANCH=release3-staging

function create_image() {
  IMAGE_SIZE=$1

  WORKDIR=$(mktemp -d)
  MNTDIR=$WORKDIR/mnt
  USERDATA_IMAGE=$WORKDIR/raw.img
  SPARSE_IMAGE=$WORKDIR/sparse.simg

  sudo umount $MNTDIR 2> /dev/null || true
  rm -rf $WORKDIR
  mkdir $WORKDIR
  cd $WORKDIR

  fallocate -l $IMAGE_SIZE $USERDATA_IMAGE
  mkfs.ext4 $USERDATA_IMAGE

  mkdir $MNTDIR
  sudo mount $USERDATA_IMAGE $MNTDIR
  sudo git clone --branch=$GIT_BRANCH --depth=1 https://github.com/commaai/openpilot.git $MNTDIR/openpilot.cache
  echo "clone done for $(sudo cat $MNTDIR/openpilot.cache/common/version.h)"
  sudo umount $MNTDIR

  echo "Sparsify"
  img2simg $USERDATA_IMAGE $SPARSE_IMAGE
  $DIR/simg2dontcare.py $SPARSE_IMAGE $OUTPUT_DIR/userdata_${sz}.img
}

for sz in 30 89 90; do
  echo "Building dashcam image for ${sz}GB"
  create_image ${sz}G
done

echo "Done!"
