#!/bin/bash -e

# Config
OUTPUT_DIR="output"
ROOTFS_IMAGE="system.img"

# Log colors
GREEN="\033[0;32m"
NO_COLOR='\033[0m'

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Flash system
fastboot --set-active=a

if [ -d $HOME/openpilot/provisioning ]; then
  DIMG=$(mktemp)
  $DIR/tools/simg2dontcare.py $OUTPUT_DIR/$ROOTFS_IMAGE $DIMG
  fastboot erase system_a
  fastboot flash system_a $DIMG
else
  fastboot flash system_a $OUTPUT_DIR/$ROOTFS_IMAGE
fi

fastboot continue

echo -e "${GREEN}Done!"
