#!/bin/bash
set -e

if [ "$(df -T / | tail -n1 | awk '{print $2}')" = "ext4" ]; then
  sudo mount -o rw,remount /
  exit 0
fi

echo "AGNOS is in read-only production mode. Switching to development mode."
echo
echo "WARNING: DO NOT power off while this script is running."
echo "If you do, use https://flash.comma.ai to recover."
echo "Once the script is done, it will automatically reboot into development mode."
echo
echo -n "Ready to continue? [y/N] "
read response
if [[ ! "$response" =~ ^[yY]$ ]]; then
    echo "Aborting."
    exit 1
fi

CUR_SLOT="$(getslotsuffix)"
if [ "$CUR_SLOT" == "_b" ]; then
  NEW_SLOT="_a"
elif [ "$CUR_SLOT" == "_a" ]; then
  NEW_SLOT="_b"
else
  echo "Invalid slot"
  exit 1
fi
echo "- cur slot: $CUR_SLOT"
echo "- new slot: $NEW_SLOT"

# copy all the partitions from the current slot to the new slot, except for system
echo "- copying partitions"
cd /dev/disk/by-partlabel
for part in $(ls | grep "${CUR_SLOT}$"); do
  base_part=$(echo "$part" | sed "s/${CUR_SLOT}$//")
  if [ "$base_part" != "system" ]; then
    echo "  - $base_part"
    dd if="$part" of="${base_part}${NEW_SLOT}" bs=1M status=none
  fi
done

# unpack the squashfs system image into an ext4 image for the other slot
set -x
echo "- unpacking squashfs image"
yes | sudo mkfs.ext4 "/dev/disk/by-partlabel/system${NEW_SLOT}" >/dev/null 2>&1
MNT="$(mktemp -d)"
sudo mount "/dev/disk/by-partlabel/system${NEW_SLOT}" $MNT
sudo rm -rf "$MNT/lost+found/"
sudo unsquashfs -d $MNT "/dev/disk/by-partlabel/system${CUR_SLOT}"
sudo umount $MNT
sync

# set the boot slot
echo "- setting new boot slot"
SLOT_NUM=0
if [ "$NEW_SLOT" == "_b" ]; then
  SLOT_NUM=1
fi
abctl --set_active $SLOT_NUM

echo
echo "All done! Rebooting into development AGNOS..."
sudo reboot
