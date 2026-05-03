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

if ! command -v runit >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y runit
fi

echo "cp runit init"
sudo mkdir -p /etc/runit
sudo cp "$ROOT"/userspace/root/etc/runit/[123] /etc/runit/
sudo rm -f /usr/bin/systemctl /usr/sbin/init /usr/sbin/reboot /usr/sbin/poweroff /usr/sbin/halt /usr/sbin/shutdown
sudo ln -sf /usr/comma/shims/systemctl /usr/bin/systemctl
sudo cp "$ROOT"/userspace/root/sbin/init /sbin/init
sudo cp "$ROOT"/userspace/root/sbin/reboot /sbin/reboot
sudo cp "$ROOT"/userspace/root/sbin/poweroff /sbin/poweroff
sudo cp "$ROOT"/userspace/root/sbin/halt /sbin/halt
sudo cp "$ROOT"/userspace/root/sbin/shutdown /sbin/shutdown
sudo chmod 755 /etc/runit/[123] /sbin/init /sbin/reboot /sbin/poweroff /sbin/halt /sbin/shutdown

sudo mount -o ro,remount /
