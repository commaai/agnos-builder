#!/bin/bash -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

./flash_bootloader.sh
./flash_kernel.sh
./flash_system.sh

fastboot continue
