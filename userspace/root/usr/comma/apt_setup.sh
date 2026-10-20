#!/bin/bash -e

# Skip inside the image builder.
if [ ! -d /run/runit ]; then
  exit 0
fi

sudo mount -o rw,remount /
sudo resize2fs $(findmnt -n -o SOURCE /) &>/dev/null || sudo resize2fs $(findmnt -n -o SOURCE /)
sudo mount -o remount,size=1500M /var
sudo cp -r /usr/default/var/lib/dpkg /var/lib/
