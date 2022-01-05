#!/bin/bash

SD="/dev/mmcblk0"
NVME="/dev/nvme0n1"
MOUNTPOINT="/data/media"

if mount $NVME $MOUNTPOINT -o discard,nosuid,nodev; then
  echo "Mounted NVMe"
  exit 0
else
  echo "Failed to mount NVMe"
fi

if mount $SD $MOUNTPOINT -o nosuid,nodev; then
  echo "Mounted SD card"
else
  echo "Failed to mount SD card"
fi
