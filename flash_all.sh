#!/bin/bash
set -e

for part in aop xbl xbl_config devcfg; do
  $EDL w ${part}_a $DIR/agnos-firmware/$part.bin
  $EDL w ${part}_b $DIR/agnos-firmware/$part.bin
done

./flash_bootloader.sh
./flash_kernel.sh
./flash_system.sh

$EDL reset
