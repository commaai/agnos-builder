#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
EDL=edl/edl
cd $DIR

flash() {
  $EDL w $1 $2 --memory=ufs | grep "Progress:"
}

for part in aop xbl xbl_config devcfg; do
  flash ${part}_a $DIR/agnos-firmware/$part.bin
  flash ${part}_b $DIR/agnos-firmware/$part.bin
done

./flash_bootloader.sh
./flash_kernel.sh
./flash_system.sh

$EDL reset > /dev/null
