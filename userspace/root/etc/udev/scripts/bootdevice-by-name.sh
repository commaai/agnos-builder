#!/bin/sh
set -e

dev="$1"
uevent="/sys/class/block/$dev/uevent"

[ -e "$uevent" ] || exit 0

boot_dev="$(sed -n 's/.*androidboot.bootdevice=\([^ ]*\).*/\1/p' /proc/cmdline | awk '{print $NF}')"
[ -n "$boot_dev" ] || exit 0

real_sysfs_path="$(realpath "/sys/class/block/$dev")"
case "$real_sysfs_path" in
  *"$boot_dev"*) ;;
  *) exit 0 ;;
esac

partition_name="$(sed -n 's/^PARTNAME=//p' "$uevent")"
[ -n "$partition_name" ] || exit 0

mkdir -p /dev/block/bootdevice/by-name
ln -sf "/dev/$dev" "/dev/block/bootdevice/by-name/$partition_name"
