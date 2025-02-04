#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ROOT=$DIR/..
OUTPUT_DIR=$DIR/../output
GIT_BRANCH=release3-staging

export DOCKER_BUILDKIT=1
docker build -f $ROOT/Dockerfile.builder -t agnos-meta-builder $DIR \
  --build-arg UNAME=$(id -nu) \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g)

function create_image() {
  IMAGE_SIZE=$1

  WORKDIR=$(mktemp -d)
  MNTDIR=$WORKDIR/mnt
  USERDATA_IMAGE=$WORKDIR/raw.img

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
  docker run --rm -u $(id -nu) --entrypoint img2simg -v $WORKDIR:$WORKDIR -v $ROOT:$ROOT -w $DIR agnos-meta-builder $USERDATA_IMAGE $OUTPUT_DIR/userdata_${sz}.img
  rm -rf $WORKDIR
}

for sz in 30 89 90; do
  echo "Building ${sz}GB userdata image"
  create_image ${sz}G
done

echo "Done!"
