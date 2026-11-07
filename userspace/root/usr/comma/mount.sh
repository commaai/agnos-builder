#!/bin/bash
# Mount the partitions here, not in fstab: a mount from fstab waits for its
# device unit, and systemd only gets those from udev. Partitions are found
# through sysfs so this doesn't wait for udev's links.

# mount.service's timeout has to stay above these two combined
PART_TIMEOUT=30
MOUNT_TIMEOUT=60

PIDS=()

# mount_part <partition> <mount point> [mount options]
# waits for the partition and mounts it in the background, reporting how it went. a stuck
# mount can't be killed and timeout would wait on it, so this races it against a timer
function mount_part {
  local part=$1 where=$2
  shift 2
  (
    until uevent=$(grep -lx "PARTNAME=$part" /sys/class/block/sd*/uevent 2>/dev/null); do
      if (( SECONDS >= PART_TIMEOUT )); then
        echo "timed out waiting for $part"
        exit 1
      fi
      sleep 0.1
    done
    dev=${uevent%/uevent}
    dev=/dev/${dev##*/}

    {
      if [ "$part" = cache ]; then
        /usr/lib/systemd/systemd-makefs ext4 "$dev" || exit 1
      fi
      mount "$@" "$dev" "$where"
    } & pid=$!
    sleep "$MOUNT_TIMEOUT" & timer=$!
    wait -n -p first "$pid" "$timer"
    ret=$?
    if [ "$first" = "$timer" ]; then
      echo "timed out mounting $where"
      exit 1
    fi
    kill "$timer"
    if [ "$ret" != 0 ]; then
      echo "failed to mount $where"
      exit 1
    fi
    echo "mounted $where"
  ) & PIDS+=($!)
}

SLOT_SUFFIX=$(sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline)

mount_part "dsp$SLOT_SUFFIX" /dsp -o ro
mount_part "modem$SLOT_SUFFIX" /firmware -o ro
mount_part persist /persist -o ro,discard,nosuid,nodev,noexec
# comma.sh handles this one failing, it starts the reset UI
mount_part userdata /data -o discard,noatime,nodiratime,nosuid,nodev
mount_part cache /cache -t ext4 -o relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
