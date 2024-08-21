#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

DOWNLOADED="aop abl xbl xbl_config devcfg"
scripts/download-from-manifest.py --master --partitions $DOWNLOADED
for part in $DOWNLOADED; do
  tools/edl w ${part}_a $DIR/agnos-firmware/$part.bin
  tools/edl w ${part}_b $DIR/agnos-firmware/$part.bin
done

./flash_kernel.sh
./flash_system.sh
