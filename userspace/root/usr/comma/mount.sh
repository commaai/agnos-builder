#!/bin/bash
# Mount the partitions here, not in fstab: a mount from fstab waits for its
# device unit, and systemd only gets those from udev. Partitions are found
# through sysfs so this doesn't wait for udev's links.

# mount.service's timeout has to stay above this plus the partition wait
MOUNT_TIMEOUT=60

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

# same arguments as mount, and reports how it went. a stuck mount can't be killed
# and timeout would wait on it, so this races it against a timer
function mount_part {
  local where=${!#} pid timer first ret
  mount "$@" & pid=$!
  sleep "$MOUNT_TIMEOUT" & timer=$!
  wait -n -p first "$pid" "$timer"
  ret=$?
  if [ "$first" = "$timer" ]; then
    echo "timed out mounting $where"
    return 1
  fi
  kill "$timer"
  if [ "$ret" = 0 ]; then
    echo "mounted $where"
  else
    echo "failed to mount $where"
    return 1
  fi
}

SLOT_SUFFIX=$(sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline)
wait_for_parts "$SLOT_SUFFIX"

PIDS=()
mount_part -o ro "${PARTS[dsp$SLOT_SUFFIX]}" /dsp & PIDS+=($!)
mount_part -o ro "${PARTS[modem_a]}" /firmware & PIDS+=($!)
mount_part -o ro,discard,nosuid,nodev,noexec "${PARTS[persist]}" /persist & PIDS+=($!)
# comma.sh handles this one failing, it starts the reset UI
mount_part -o discard,noatime,nodiratime,nosuid,nodev "${PARTS[userdata]}" /data & PIDS+=($!)
(
  if ! /usr/lib/systemd/systemd-makefs ext4 "${PARTS[cache]}"; then
    echo "failed to format /cache"
    exit 1
  fi
  mount_part -t ext4 -o relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid "${PARTS[cache]}" /cache
) & PIDS+=($!)

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
