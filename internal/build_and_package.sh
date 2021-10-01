#!/bin/bash -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR/..

read -p "Is the kernel repo up to date? " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Update it and run again!"
  [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1
fi

read -p "Is the firmware repo up to date? Copied in the new abl if needed? " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Update it and run again!"
  [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1
fi

./build_kernel.sh
cp output/wlan.ko userspace/usr/comma
cp output/snd*.ko userspace/usr/comma/sound/
./build_system.sh
internal/package_ota.sh
