#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

EDL_DIR=$DIR/edl
if [ ! -d  $EDL_DIR ]; then
  ./install_edl.sh
fi

for part in aop xbl xbl_config devcfg; do
  $EDL_DIR/edl w ${part}_a $DIR/agnos-firmware/$part.bin
  $EDL_DIR/edl w ${part}_b $DIR/agnos-firmware/$part.bin
done

./flash_bootloader.sh
./flash_kernel.sh
./flash_system.sh

$EDL_DIR/edl reset
