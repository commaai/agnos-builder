#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ROOT=$DIR/../

if [ ! -f /AGNOS ]; then
  echo "Exiting, not running AGNOS"
  exit 1
fi

sudo mount -o rw,remount /
sudo resize2fs $(findmnt -n -o SOURCE /)

echo "symlink /usr/comma"
sudo rm -rf /usr/comma
sudo ln -snf $ROOT/userspace/root/usr/comma/ /usr/comma

echo "cp systemd services"
for s in "$ROOT"/userspace/root/lib/systemd/system/*.{service,path,timer,mount} "$ROOT"/userspace/files/ModemManager.service; do
  [ -e "$s" ] || continue
  service=$(basename $s)
  echo "- $service"
  sudo rm -f /lib/systemd/system/$service
  sudo cp "$s" /lib/systemd/system/
done
sudo $ROOT/userspace/services.sh

sudo mount -o ro,remount /
