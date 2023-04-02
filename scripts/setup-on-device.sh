#!/usr/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ROOT=$DIR/../

if [ ! -f /AGNOS ]; then
  echo "Exiting, not running AGNOS"
  exit 1
fi

sudo mount -o rw,remount /

sudo rm -rf /usr/comma
sudo ln -snf $ROOT/userspace/usr/comma/ /usr/comma

sudo mount -o ro,remount /
