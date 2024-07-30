#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# TODO: download firmware from firmware.json
#for part in aop abl xbl xbl_config devcfg; do
#  tools/edl w ${part}_a $DIR/agnos-firmware/$part.bin
#  tools/edl w ${part}_b $DIR/agnos-firmware/$part.bin
#done

./flash_kernel.sh
./flash_system.sh
