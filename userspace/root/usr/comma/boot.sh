#!/bin/bash

# ******************************************************************************************
# boot.sh: a single script to boot comma devices. the boot.sh philosophy:
# > booting is effectively kernel -> boot.sh -> app (e.g. openpilot). boot.sh should be able
#   to function as an init directly without a traditional init system like systemd.
# > for speed, each init function starts immediately and runs in the background
# > for locality, each init function manages its own dependencies
# > no late handling. the state once boot.sh is done is the state the system will remain in,
#   with specific exceptions, such as USB devices the user may hotplug.
# > fail loudly. nothing is optional and any failure results in a failed exit code
# > failures should be contained and have defined error states. a single failed mount or 
#   subsystem boot does not hang the whole process or impact the rest of the system
# ******************************************************************************************

# boot.service's systemd timeout has to stay above this
INIT_TIMEOUT=120
PARTITION_TIMEOUT=5
# above PARTITION_TIMEOUT, a mount still has to find its partition and maybe format it
MOUNT_TIMEOUT=10
# a driver that has its firmware probes in well under a second, and the ADSP and its sound card in ~1s
DEVICE_TIMEOUT=10

PIDS=()

# run_init <function>
# runs the function in the background, reporting how it went. it stops at its first failure,
# unless it opts out with set +e. a stuck open can't be killed
# and timeout would wait on it, so this gives up on reading its status instead
function run_init {
  local name=$1
  (
    start=${EPOCHREALTIME/./}
    if ! read -r -t "$INIT_TIMEOUT" ret < <((set -e; "$name") >&2; echo $?); then
      echo -e "\e[31m$name timed out\e[0m"
      exit 1
    fi
    ms=$(( (${EPOCHREALTIME/./} - start) / 1000 ))
    printf -v took '%d.%02ds' $(( ms / 1000 )) $(( ms % 1000 / 10 ))
    if [ "$ret" != 0 ]; then
      echo -e "\e[31m$name failed in $took\e[0m"
      exit 1
    fi
    echo -e "\e[32m$name done in $took\e[0m"
  ) & PIDS+=($!)
}

# part_dev <partition>
# prints the partition's device. it's found through sysfs so this doesn't wait for udev's links
function part_dev {
  local uevent start=$SECONDS
  until uevent=$(grep -lx "PARTNAME=$1" /sys/class/block/sd*/uevent 2>/dev/null); do
    (( SECONDS - start < PARTITION_TIMEOUT )) || { echo "no partition $1" >&2; return 1; }
    sleep 0.1
  done
  uevent=${uevent%/uevent}
  echo "/dev/${uevent##*/}"
}

# mount_part <partition> <mount point> [mount options]
# partitions are mounted here, not in fstab: a mount from fstab waits for its device unit,
# and systemd only gets those from udev
function mount_part {
  local dev
  dev=$(part_dev "$1")
  mount "${@:3}" "$dev" "$2"
}

# wait_mount <mount point>
function wait_mount {
  local start=$SECONDS
  until mountpoint -q "$1"; do
    (( SECONDS - start < MOUNT_TIMEOUT )) || { echo "$1 not mounted"; return 1; }
    sleep 0.01
  done
}

# OTAs don't write this, so both slots use slot a's copy
function mount_firmware {
  mount_part modem_a /firmware -o ro
}

function mount_persist {
  mount_part persist /persist -o ro,discard,nosuid,nodev,noexec
}

function mount_data {
  mount_part userdata /data -o discard,noatime,nodiratime,nosuid,nodev
  # first, so comma.sh can still clean up /data if something below fails
  chown comma: /data
  rm -rf /data/tmp
  # the rootfs symlinks /etc paths to these, and tqftpserv serves the modem's files from the last one
  mkdir -p /data/etc/netplan /data/etc/NetworkManager/system-connections /data/ssh /data/tmp \
    /data/persist/rfs/msm/mpss
  touch /data/etc/timezone /data/etc/localtime
  chown comma: /data/ssh /data/tmp
}

function mount_cache {
  local opts=(-t ext4 -o relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid)
  if ! mount_part cache /cache "${opts[@]}"; then
    # it's blank on first boot, and it only holds debug logs, so format it whenever it won't mount
    mkfs.ext4 -F -q "$(part_dev cache)"
    mount_part cache /cache "${opts[@]}"
  fi
  chown comma: /cache
}

function mount_tmp {
  # openpilot's queues are in /dev/shm and its sockets in /tmp. at ~1 kB of memory per file,
  # something leaking files hits its memory limit before it takes the last inode
  mount -t tmpfs -o rw,nosuid,nodev,size=150M,nr_inodes=1M,mode=1777 tmpfs /tmp
  mount -o remount,nr_inodes=1M /dev/shm
}

function mount_var {
  mount -t tmpfs -o rw,nosuid,nodev,size=128M,mode=755 tmpfs /var
  mkdir /var/log
  mount -t tmpfs -o rw,nosuid,nodev,size=128M,mode=755 tmpfs /var/log
  systemd-tmpfiles --create /usr/comma/tmpfiles.conf
}

function mount_home {
  mount -t tmpfs -o rw,nosuid,nodev,size=100M,mode=1777 tmpfs /rwtmp
  mkdir /rwtmp/home_work /rwtmp/home_upper
  mount -t overlay overlay -o lowerdir=/usr/default/home,upperdir=/rwtmp/home_upper,workdir=/rwtmp/home_work /home
}

# wait_for <what> <command...>
# polls the command until it succeeds
function wait_for {
  local start=$SECONDS
  until "${@:2}"; do
    (( SECONDS - start < DEVICE_TIMEOUT )) || { echo "no $1"; return 1; }
    sleep 0.01
  done
}

# video_node <name>
# prints the V4L2 node with that name. drivers register them in any order
function video_node {
  local d
  for d in /sys/class/video4linux/video*; do
    [ "$(< "$d/name")" = "$1" ] && { echo "/dev/${d##*/}"; return 0; }
  done 2>/dev/null
  return 1
}

# remoteproc_running <name>
function remoteproc_running {
  local d
  for d in /sys/class/remoteproc/remoteproc*; do
    [ "$(< "$d/name")" = "$1" ] && [ "$(< "$d/state")" = running ] && return 0
  done 2>/dev/null
  return 1
}

# there's no udev to load modules, so whichever job needs a device loads its driver. the ones that
# are modules rather than built in need /firmware when they probe, see kernel/README.md
function start_venus {
  wait_mount /firmware
  # it boots the video firmware as it probes, and then each core registers its node
  modprobe -a venus_core venus_enc venus_dec
  local name node
  for name in qcom-venus-encoder qcom-venus-decoder; do
    wait_for "$name" video_node "$name" > /dev/null
    node=$(video_node "$name")
    chgrp video "$node"
    chmod 660 "$node"
  done
}

function start_camera {
  # its ICP firmware is in the rootfs, and only loads when camerad acquires the ICP
  modprobe spectra_camera
  wait_for cam-req-mgr video_node cam-req-mgr > /dev/null
  wait_for cam_sync video_node cam_sync > /dev/null
  local req sync
  req=$(video_node cam-req-mgr)
  sync=$(video_node cam_sync)
  # camerad opens these paths, as udev named them on the downstream kernel
  mkdir -p /dev/v4l/by-path
  ln -sf "../../${req##*/}" /dev/v4l/by-path/platform-soc:qcom_cam-req-mgr-video-index0
  ln -sf "../../${sync##*/}" /dev/v4l/by-path/platform-cam_sync-video-index0
  chgrp video "$req" "$sync" /dev/media* /dev/v4l-subdev*
  chmod 660 "$req" "$sync" /dev/media* /dev/v4l-subdev*
}

function start_sound {
  wait_mount /firmware
  local card capture
  if grep -q mici /sys/firmware/devicetree/base/model; then
    card=commamici capture=SEC_MI2S_TX
  else
    card=commatizi capture=TERT_MI2S_TX
  fi

  # the ADSP boots in the background once its driver probes. its services come up with it, and
  # the sound card registers once they have, so the card being there means sound is ready
  modprobe qcom_q6v5_pas
  wait_for "ADSP" remoteproc_running adsp
  wait_for "sound card $card" test -d "/proc/asound/$card"

  # playback is MultiMedia1 (device 0), capture is MultiMedia2 (device 1)
  amixer -c "$card" -q cset "name='SEC_MI2S_RX Audio Mixer MultiMedia1'" 1
  amixer -c "$card" -q cset "name='MultiMedia2 Mixer $capture'" 1

  # mici has no amp config, and starting Python to find that out is most of this job
  [ "$card" = commamici ] || /usr/local/venv/bin/python /usr/comma/sound/amplifier.py

  find /dev/snd -maxdepth 1 -type c -exec chgrp audio {} + -exec chmod 660 {} +
}

function start_wifi {
  # the firmware reports 0e:00:00:00:00:00. give the interface the address the downstream driver
  # did, the 00:0a:f5 OUI and the low 3 bytes of the SoC serial number. NetworkManager starts after
  # boot.sh, and sets it whenever it brings wlan0 up
  local serial
  serial=$(< /sys/devices/soc0/serial_number)
  (( serial > 0 ))
  mkdir -p /run/NetworkManager/conf.d
  printf '[connection-wlan-mac]\nmatch-device=interface-name:wlan0\nwifi.cloned-mac-address=00:0a:f5:%02x:%02x:%02x\n' \
    $(( serial >> 16 & 255 )) $(( serial >> 8 & 255 )) $(( serial & 255 ))  > /run/NetworkManager/conf.d/wlan-mac.conf

  # wlan0 only shows up once the modem is running, which rmtfs.service starts after boot.sh
  modprobe ath10k_snoc
}

function set_hostname {
  local serial
  serial=$(sed -e 's/^.*androidboot.serialno=//' -e 's/ .*$//' /proc/cmdline)
  echo "comma-$serial" > /proc/sys/kernel/hostname
}

function setup_devices {
  # all of these should be there, so a missing one fails boot and the command that hit it says which.
  # keep going so it doesn't take the rest with it, and fail at the end
  set +e
  local ret=0
  trap 'ret=1' ERR

  # rmtfs serves the EFS partitions to the modem. the others are for the updater, reset and hardware.h
  local parts=(modemst1 modemst2 fsc fsg persist ssd userdata {abl,aop,boot,devcfg,system,xbl,xbl_config}_{a,b})
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

  chgrp gpu /dev/dri/{card,renderD}* /dev/dma_heap/system
  # the 3X has no high speed UART
  local uart=()
  [ -e /dev/ttyHS0 ] && uart=(/dev/ttyHS*)
  # sensord takes the IMU interrupt from the TLMM's character device
  local tlmm
  tlmm=$(ls -d /sys/bus/platform/devices/3400000.pinctrl/gpiochip*)
  tlmm=/dev/${tlmm##*/}
  # /sys/class/gpio is for provisioning, it exports its pins as comma
  chgrp gpio "$tlmm" /dev/i2c-* "${uart[@]}" /sys/class/gpio/{export,unexport}
  chgrp input /dev/input/event*
  chgrp disk /dev/sd*
  chgrp dialout /dev/ttyMSM*
  chmod 660 /dev/dri/{card,renderD}* /dev/dma_heap/system \
    "$tlmm" /dev/i2c-* "${uart[@]}" /sys/class/gpio/{export,unexport} \
    /dev/sd* \
    /dev/ttyMSM*
  chmod 666 /dev/input/event* /dev/fuse /dev/net/tun /dev/spidev*
  chmod 664 /dev/rfkill

  # not every display and LED is on every device
  local attr video_attrs=()
  for attr in /sys/class/backlight/*/{brightness,bl_power} /sys/class/leds/ir:torch/brightness; do
    [ -e "$attr" ] && video_attrs+=("$attr")
  done
  chgrp video "${video_attrs[@]}"
  chmod 664 "${video_attrs[@]}"

  mkdir -p /dev/disk/by-partlabel /dev/input/by-path

  local line path dev name
  for line in "${found[@]}"; do
    IFS== read -r path name <<< "$line"
    dev=${path%/uevent:PARTNAME}
    ln -sf "../../${dev##*/}" "/dev/disk/by-partlabel/$name"
  done

  # input devices can enumerate in any order
  path=$(ls -d /sys/bus/platform/devices/894000.i2c/i2c-*/*/input/input*/event*)
  ln -sf "../${path##*/}" /dev/input/by-path/platform-894000.i2c-event

  return $ret
}

function setup_gpios {
  # keep going so one bad pin doesn't take the rest with it, and fail at the end
  set +e
  local ret=0
  trap 'ret=1' ERR

  # openpilot drives these through the legacy sysfs ABI, as gpio<TLMM base + pin>. lte.sh and
  # power_drop_monitor.py take theirs by name from the character device, which an export would block
  local pins=(
    49   # SOM_ST_IO
    134  # ST_BOOT0
    124  # ST_RST_N
    34   # GPS_PWR_EN, not connected on mici but pigeond still drives it
  )
  if grep -q mici /sys/firmware/devicetree/base/model; then
    pins+=(
      33   # GPS_SAFEBOOT_N
      32   # GPS_RST_N
    )
  fi

  # the kernel numbers the chips as they probe
  local base
  base=$(cat /sys/bus/platform/devices/3400000.pinctrl/gpio/gpiochip*/base)

  local p d nodes=()
  for p in "${pins[@]}"; do
    echo $(( base + p )) > /sys/class/gpio/export
    d=/sys/class/gpio/gpio$(( base + p ))
    nodes+=("$d" "$d"/{active_low,direction,edge,value})
  done
  chgrp -f gpio "${nodes[@]}"
  chmod -f 770 "${nodes[@]}"

  # the internal USB hub's reset, which nothing else drives
  # shellcheck disable=SC2046  # gpiofind prints the chip and the offset
  gpioset $(gpiofind HUB_RST_N)=1

  return $ret
}

run_init mount_firmware
run_init mount_persist
run_init mount_data
run_init mount_cache
run_init mount_tmp
run_init mount_var
run_init mount_home
run_init start_venus
run_init start_camera
run_init start_sound
run_init start_wifi
run_init set_hostname
run_init setup_devices
run_init setup_gpios

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
