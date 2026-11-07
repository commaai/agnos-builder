#!/bin/bash
# each init starts immediately in the background and waits for whatever it needs itself

# boot.service's timeout has to stay above this
INIT_TIMEOUT=120

PIDS=()

# run_init <function>
# runs the function in the background, reporting how it went. a stuck open can't be killed
# and timeout would wait on it, so this races it against a timer
function run_init {
  local name=$1
  (
    "$name" & pid=$!
    sleep "$INIT_TIMEOUT" & timer=$!
    wait -n -p first "$pid" "$timer"
    ret=$?
    if [ "$first" = "$timer" ]; then
      echo "$name timed out"
      exit 1
    fi
    kill "$timer"
    if [ "$ret" != 0 ]; then
      echo "$name failed"
      exit 1
    fi
    echo "$name done"
  ) & PIDS+=($!)
}

# mount_part <partition> <mount point> [mount options]
# partitions are mounted here, not in fstab: a mount from fstab waits for its device unit,
# and systemd only gets those from udev. they're found through sysfs so this doesn't wait
# for udev's links
function mount_part {
  local part=$1 where=$2 uevent dev
  shift 2
  until uevent=$(grep -lx "PARTNAME=$part" /sys/class/block/sd*/uevent 2>/dev/null); do
    sleep 0.1
  done
  dev=${uevent%/uevent}
  dev=/dev/${dev##*/}
  if [ "$part" = cache ]; then
    /usr/lib/systemd/systemd-makefs ext4 "$dev" || return 1
  fi
  mount "$@" "$dev" "$where"
}

SLOT_SUFFIX=$(sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline)

function mount_dsp {
  mount_part "dsp$SLOT_SUFFIX" /dsp -o ro
}

function mount_firmware {
  mount_part "modem$SLOT_SUFFIX" /firmware -o ro
}

function mount_persist {
  mount_part persist /persist -o ro,discard,nosuid,nodev,noexec
}

function mount_data {
  mount_part userdata /data -o discard,noatime,nodiratime,nosuid,nodev
}

function mount_cache {
  mount_part cache /cache -t ext4 -o relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid
}

function set_restart_levels {
  # don't restart whole SoC on subsystem crash
  echo related | tee /sys/bus/msm_subsys/devices/subsys*/restart_level > /dev/null
}

function start_venus {
  until mountpoint -q /firmware; do
    sleep 0.01
  done
  until [ -e /dev/video33 ]; do
    sleep 0.01
  done
  # opening the node boots the venus encoder
  : < /dev/video33
}

run_init mount_dsp
run_init mount_firmware
run_init mount_persist
run_init mount_data
run_init mount_cache
run_init set_restart_levels
run_init start_venus

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
