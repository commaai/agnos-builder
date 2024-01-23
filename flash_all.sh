#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

for part in aop xbl xbl_config devcfg; do
  edl w ${part}_a $DIR/agnos-firmware/$part.bin
  edl w ${part}_b $DIR/agnos-firmware/$part.bin
done

./flash_bootloader.sh
./flash_kernel.sh
./flash_system.sh

fastboot continue
