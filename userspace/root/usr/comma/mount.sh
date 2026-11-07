#!/bin/bash
# Mount the partitions here, not in fstab: a mount from fstab waits for its
# device unit, and systemd only gets those from udev. Partitions are found
# through sysfs so this doesn't wait for udev's links.

declare -A PARTS

function wait_for_parts {
  local uevent line
  while (( SECONDS < 30 )); do
    for uevent in /sys/class/block/sd*/uevent; do
      while read -r line; do
        [[ $line == PARTNAME=* ]] && PARTS[${line#PARTNAME=}]=/dev/${uevent:17:-7}
      done < "$uevent"
    done
    [[ -n ${PARTS[userdata]} && -n ${PARTS[cache]} && -n ${PARTS[persist]} && -n ${PARTS[modem_a]} && -n ${PARTS[dsp$1]} ]] && return
    sleep 0.1
  done
  echo "timed out waiting for partitions"
}

function mount_cache {
  /usr/lib/systemd/systemd-makefs ext4 "${PARTS[cache]}" &&
    mount -t ext4 -o relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid "${PARTS[cache]}" /cache
}

function report {
  local where=$1
  shift
  if "$@"; then
    echo "mounted $where"
  else
    echo "failed to mount $where"
    return 1
  fi
}

SLOT_SUFFIX=$(sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline)
wait_for_parts "$SLOT_SUFFIX"

PIDS=()
report /dsp mount -o ro "${PARTS[dsp$SLOT_SUFFIX]}" /dsp & PIDS+=($!)
report /firmware mount -o ro "${PARTS[modem_a]}" /firmware & PIDS+=($!)
report /persist mount -o ro,discard,nosuid,nodev,noexec "${PARTS[persist]}" /persist & PIDS+=($!)
# comma.sh handles this one failing, it starts the reset UI
report /data mount -o discard,noatime,nodiratime,nosuid,nodev "${PARTS[userdata]}" /data & PIDS+=($!)
report /cache mount_cache & PIDS+=($!)

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
