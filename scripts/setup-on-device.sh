#!/usr/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ROOT=$DIR/../

if [ ! -f /AGNOS ]; then
  echo "Exiting, not running AGNOS"
  exit 1
fi

sudo mount -o rw,remount /

# symlink /usr/comma/
echo "symlink /usr/comma"
sudo rm -rf /usr/comma
sudo ln -snf $ROOT/userspace/usr/comma/ /usr/comma

# symlink services
echo "symlink systemd services"
for s in $(ls $ROOT/userspace/files/*.service); do
  service=$(basename $s)
  echo "- $service"
  sudo rm -f /lib/systemd/system/$service
  sudo ln -sf $ROOT/userspace/files/*.service /lib/systemd/system/
done
sudo $ROOT/userspace/services.sh

sudo mount -o ro,remount /
