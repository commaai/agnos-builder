#!/bin/bash
set -e
# Match the permissions of the original root-owned clone.
umask 022

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
OUTPUT_DIR=$DIR/../output
GIT_BRANCH="release-tizi-staging"
RELEASE_BRANCH="release-tizi"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
ROOTFS=$WORKDIR/rootfs
mkdir -p $ROOTFS $OUTPUT_DIR

git clone --branch=$GIT_BRANCH --depth=1 https://github.com/commaai/openpilot.git $ROOTFS/openpilot
touch $ROOTFS/.openpilot_cache

git -C $ROOTFS/openpilot remote set-branches --add origin $RELEASE_BRANCH
git -C $ROOTFS/openpilot update-ref refs/remotes/origin/$RELEASE_BRANCH refs/remotes/origin/$GIT_BRANCH
git -C $ROOTFS/openpilot branch -m $RELEASE_BRANCH
git -C $ROOTFS/openpilot branch --set-upstream-to=origin/$RELEASE_BRANCH

echo "clone done for $(cat $ROOTFS/openpilot/common/version.h)"

for sz in 89 90; do
  echo "Building ${sz}GB userdata image"
  USERDATA_IMAGE=$WORKDIR/raw.img
  truncate -s 0 $USERDATA_IMAGE
  truncate -s ${sz}G $USERDATA_IMAGE

  # Populate without mounting, preserving the device's root and comma ownership.
  fakeroot sh -ec '
    chown -R 0:0 "$1"
    chown -R 1000:1000 "$1/openpilot"
    mkfs.ext4 -F -E root_owner=0:0 -d "$1" "$2"
  ' sh $ROOTFS $USERDATA_IMAGE

  # Skip host filesystem holes instead of reading 89-90GB of zeros.
  img2simg -s $USERDATA_IMAGE $WORKDIR/sparse.img
  python3 $DIR/sparse_fill.py $WORKDIR/sparse.img $OUTPUT_DIR/userdata_${sz}.img
done

echo "Done!"
