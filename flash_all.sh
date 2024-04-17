#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

source $DIR/tools/setup_edl_commands.sh

for part in aop xbl xbl_config devcfg; do
  flash ${part}_a $DIR/agnos-firmware/$part.bin
  flash ${part}_b $DIR/agnos-firmware/$part.bin
done

./flash_bootloader.sh
./flash_kernel.sh
./flash_system.sh

