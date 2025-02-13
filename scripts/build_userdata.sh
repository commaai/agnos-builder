#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ROOT=$DIR/..
OUTPUT_DIR=$DIR/../output
GIT_BRANCH=release3-staging

WORKDIR=$(mktemp -d)
MNTDIR=$WORKDIR/mnt
USERDATA_IMAGE=$WORKDIR/raw.img

export DOCKER_BUILDKIT=1
docker buildx build --load -f $ROOT/Dockerfile.builder -t agnos-meta-builder $DIR \
  --build-arg UNAME=$(id -nu) \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g)
MOUNT_CONTAINER_ID=$(docker run -d --privileged -v $WORKDIR:$WORKDIR -v $ROOT:$ROOT agnos-meta-builder)

trap "echo \"Cleaning up containers:\"; \
docker container rm -f $MOUNT_CONTAINER_ID" EXIT

exec_as_user() {
  docker exec -u $(id -nu) $MOUNT_CONTAINER_ID "$@"
}

exec_as_root() {
  docker exec $MOUNT_CONTAINER_ID "$@"
}

function create_image() {
  IMAGE_SIZE=$1

  exec_as_root umount $MNTDIR 2> /dev/null || true
  exec_as_root rm -rf $WORKDIR/*

  exec_as_root fallocate -l $IMAGE_SIZE $USERDATA_IMAGE
  exec_as_root mkfs.ext4 $USERDATA_IMAGE

  exec_as_root mkdir $MNTDIR
  exec_as_root mount $USERDATA_IMAGE $MNTDIR
  sudo git clone --branch=$GIT_BRANCH --depth=1 https://github.com/commaai/openpilot.git $WORKDIR/openpilot.cache
  echo "clone done for $(sudo cat $WORKDIR/openpilot.cache/common/version.h)"
  exec_as_root mv $WORKDIR/openpilot.cache $MNTDIR/
  exec_as_root umount $MNTDIR

  echo "Sparsify"
  #exec_as_user img2simg $USERDATA_IMAGE $OUTPUT_DIR/userdata_${sz}.img
  exec_as_root rm -rf $WORKDIR/*
}

for sz in 30 89 90; do
  echo "Building ${sz}GB userdata image"
  create_image ${sz}G
done

echo "Done!"
