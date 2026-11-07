#!/bin/bash
# each init starts immediately in the background and waits for whatever it needs itself

# boot.service's timeout has to stay above this
INIT_TIMEOUT=120
PARTITION_TIMEOUT=5

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

function start_cdsp {
  local start=$SECONDS
  until mountpoint -q /firmware; do
    (( SECONDS - start < PARTITION_TIMEOUT )) || { echo "/firmware not mounted"; return 1; }
    sleep 0.01
  done
  while grep -qvx RELATED /sys/bus/msm_subsys/devices/subsys*/restart_level; do
    (( SECONDS - start < PARTITION_TIMEOUT )) || { echo "restart levels not set"; return 1; }
    sleep 0.01
  done
  # only queues the load, the cdsp comes up in the background
  echo 1 > /sys/kernel/boot_cdsp/boot
}

function set_firmware_timeout {
  # nothing in userspace provides firmware, a request for a missing one would wait 60s
  echo 1 > /sys/class/firmware/timeout
}

function set_hostname {
  local serial
  serial=$(sed -e 's/^.*androidboot.serialno=//' -e 's/ .*$//' /proc/cmdline)
  echo "comma-$serial" > /proc/sys/kernel/hostname
}

function setup_devices {
  # keep going so one missing node doesn't take the rest with it, and fail at the end
  local ret=0
  trap 'ret=1' ERR
  shopt -s nullglob

  # rmt_storage reads the EFS partitions by name. the others are for the updater, reset and hardware.h
  local efs=(modemst1 modemst2 fsc fsg)
  local parts=("${efs[@]}" persist ssd userdata {abl,aop,boot,devcfg,system,xbl,xbl_config}_{a,b})
  local pattern
  pattern="^PARTNAME=($(IFS='|'; echo "${parts[*]}"))\$"

  # the UFS LUNs might still be probing
  local found start=$SECONDS
  while mapfile -t found < <(grep -HE "$pattern" /sys/class/block/sd*/uevent); do
    (( ${#found[@]} < ${#parts[@]} && SECONDS - start < PARTITION_TIMEOUT )) || break
    sleep 0.01
  done
  if (( ${#found[@]} < ${#parts[@]} )); then
    echo "only found ${#found[@]} of ${#parts[@]} partitions"
    ret=1
  fi

  chgrp gpu /dev/adsprpc-smd /dev/ion /dev/kgsl-3d0 /dev/dri/{card,controlD,renderD}*
  # /sys/class/gpio is for provisioning, it exports its pins as comma
  chgrp gpio /dev/gpiochip0 /dev/i2c-* /dev/ttyHS* /sys/class/gpio/{export,unexport}
  chgrp input /dev/input/{event,mouse}* /dev/input/mice
  chgrp video /dev/media* /dev/v4l-subdev* /dev/video*
  chgrp disk /dev/sd* /dev/sg*
  chgrp dialout /dev/ttyMSM*
  chmod 660 /dev/adsprpc-smd /dev/ion /dev/kgsl-3d0 /dev/dri/{card,controlD,renderD}* \
    /dev/gpiochip0 /dev/i2c-* /dev/ttyHS* /sys/class/gpio/{export,unexport} \
    /dev/media* /dev/v4l-subdev* /dev/video* \
    /dev/sd* /dev/sg* \
    /dev/ttyMSM*
  chmod 666 /dev/input/{event,mouse}* /dev/input/mice /dev/fuse /dev/net/tun /dev/spidev*

  # not every display and LED is on every device
  local attr video_attrs=()
  for attr in /sys/class/backlight/panel0-backlight/{brightness,bl_power} \
      /sys/class/leds/led:{torch,switch}_2/brightness \
      /sys/devices/platform/soc/soc:qcom,dsi-display@0/max_brightness_percent; do
    [ -e "$attr" ] && video_attrs+=("$attr")
  done
  chgrp video "${video_attrs[@]}"
  chmod 664 "${video_attrs[@]}"

  mkdir -p /dev/disk/by-partlabel /dev/block/bootdevice/by-name /dev/input/by-path /dev/v4l/by-path

  local line path dev name
  for line in "${found[@]}"; do
    IFS== read -r path name <<< "$line"
    dev=${path%/uevent:PARTNAME}
    dev=${dev##*/}
    case " ${efs[*]} " in
      *" $name "*) ln -sf "../../../$dev" "/dev/block/bootdevice/by-name/$name" ;;
      *) ln -sf "../../$dev" "/dev/disk/by-partlabel/$name" ;;
    esac
  done

  # the touchscreen and cameras can enumerate in any order
  for path in /sys/devices/platform/soc/894000.i2c/i2c-*/*/input/input*/event*; do
    ln -sf "../${path##*/}" /dev/input/by-path/platform-894000.i2c-event
  done
  for path in /sys/devices/platform/soc/soc:qcom,cam-req-mgr/video4linux/video*; do
    ln -sf "../../${path##*/}" /dev/v4l/by-path/platform-soc:qcom_cam-req-mgr-video-index0
  done
  for path in /sys/devices/platform/cam_sync/video4linux/video*; do
    ln -sf "../../${path##*/}" /dev/v4l/by-path/platform-cam_sync-video-index0
  done
  ln -sf ../../video33 /dev/v4l/by-path/platform-aa00000.qcom_vidc-video-index1

  return $ret
}

function setup_gpios {
  # a UP's TCAN driver owns some of these and nothing there uses them, it exports its own
  grep -q "ultimate provisioning" /sys/firmware/devicetree/base/model && return 0

  # keep going so one bad pin doesn't take the rest with it, and fail at the end
  local ret=0
  trap 'ret=1' ERR

  local pins=(
    49   # SOM_ST_IO
    134  # ST_BOOT0
    50   # LTE_RST_N
    116  # LTE_PWRKEY
    124  # ST_RST_N
    34   # GPS_PWR_EN, not connected on mici but pigeond still drives it
    52   # LTE_BOOT
  )
  if grep -q mici /sys/firmware/devicetree/base/model; then
    pins+=(
      33   # GPS_SAFEBOOT_N
      32   # GPS_RST_N
    )
  elif grep -q tizi /sys/firmware/devicetree/base/model; then
    pins+=(1264) # POWER ALERT
  fi

  local p d nodes=()
  for p in "${pins[@]}"; do
    echo "$p" > /sys/class/gpio/export
    d=/sys/class/gpio/gpio$p
    nodes+=("$d" "$d"/{active_low,direction,edge,value})
  done
  chgrp -f gpio "${nodes[@]}"
  chmod -f 770 "${nodes[@]}"

  return $ret
}

run_init mount_dsp
run_init mount_firmware
run_init mount_persist
run_init mount_data
run_init mount_cache
run_init set_restart_levels
run_init start_venus
run_init start_cdsp
run_init set_firmware_timeout
run_init set_hostname
run_init setup_devices
run_init setup_gpios

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
