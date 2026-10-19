#!/bin/bash

# this file boots and sets up all state necessary for the comma service, including
# filesystem mounting and booting Qualcomm peripherals, such as WLAN and DSPs.

PATH=/usr/sbin:/usr/bin:/sbin:/bin

function log_console {
  # log to the serial console to make boot time debugging ez pz
  local msg="comma-init: $*"

  echo "$msg"
  echo "$msg" > /dev/console
}

function run_init {
  local name="$1"
  local start_time end_time elapsed_us elapsed_tenths elapsed ret

  log_console "$name started"
  start_time="${EPOCHREALTIME/./}"

  "$name"
  ret=$?

  end_time="${EPOCHREALTIME/./}"
  elapsed_us=$((end_time - start_time))
  elapsed_tenths=$(((elapsed_us + 50000) / 100000))
  printf -v elapsed "%d.%d" "$((elapsed_tenths / 10))" "$((elapsed_tenths % 10))"
  log_console "$name finished after ${elapsed}s with ${ret}"
  return $ret
}

function await {
  local timeout=0
  local start now timeout_us

  if [[ "$1" =~ ^[0-9]+$ ]]; then
    timeout="$1"
    shift
    start="${EPOCHREALTIME/./}"
    timeout_us=$((timeout * 1000000))
  fi

  while ! "$@"; do
    if ((timeout > 0)); then
      now="${EPOCHREALTIME/./}"
      ((now - start >= timeout_us)) && return 1
    fi
    sleep 0.01
  done
}

function init_permissions (
  chmod 0666 /dev/spidev0.0
  chmod 0666 /dev/input/event*
  chgrp gpio /dev/ttyHS0
  chmod 0660 /dev/ttyHS0

  for path in \
    /sys/class/backlight/panel0-backlight/brightness \
    /sys/class/backlight/panel0-backlight/bl_power \
    /sys/devices/platform/soc/soc:qcom,dsi-display@0/max_brightness_percent \
    /sys/class/leds/led:torch_2/brightness \
    /sys/class/leds/led:switch_2/brightness
  do
    chgrp video "$path"
    chmod g+w "$path"
  done

  # gpu group
  for path in /dev/kgsl-3d0 /dev/ion /dev/dri/card* /dev/dri/controlD* /dev/dri/renderD*; do
    [[ -c "$path" ]] || continue
    chgrp gpu "$path"
    chmod 0660 "$path"
  done

  # setup gpio group
  for path in /dev/i2c-* /dev/gpiochip0; do
    [[ -c "$path" ]] || continue
    chgrp gpio "$path"
    chmod 0660 "$path"
  done
)

function init_filesystems (
  function mount_fs {
    local what="$1"
    local where="$2"
    local type="$3"
    local options="$4"

    if [[ "$what" == /dev/* ]] && ! await 3 test -b "$what"; then
      log_console "timed out waiting for $where"
      return 1
    fi

    if mount --mkdir -t "$type" -o "$options" "$what" "$where"; then
      log_console "mounted $where"
      return 0
    fi
    log_console "failed mounting $where"
  }

  # mount base filesystems
  mount_fs /dev/sde9 /dsp ext4 ro &
  mount_fs /dev/sde4 /firmware vfat ro &
  mount_fs /dev/sda2 /persist auto ro,nosuid,nodev,noexec &
  mount_fs /dev/sda12 /data ext4 discard,noatime,nodiratime,nosuid,nodev &
  mount_fs /dev/sda11 /cache ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid &
  mount_fs tmpfs /var tmpfs rw,nosuid,nodev,size=128M,mode=755 &
  mount_fs tmpfs /tmp tmpfs rw,nosuid,nodev,size=150M,mode=1777 &
  mount_fs tmpfs /rwtmp tmpfs rw,nosuid,nodev,size=100M,mode=1777 &
  wait

  # Preserve partition aliases for rmt_storage and image update tools without udev.
  mkdir -p /dev/block/bootdevice/by-name /dev/disk/by-partlabel
  for partition in /sys/class/block/sd*/uevent; do
    [[ -f "$partition" ]] || continue
    local name label
    name="$(sed -n 's/^DEVNAME=//p' "$partition")"
    label="$(sed -n 's/^PARTNAME=//p' "$partition")"
    [[ -n "$name" && -n "$label" ]] || continue
    ln -sf "/dev/$name" "/dev/block/bootdevice/by-name/$label"
    ln -sf "/dev/$name" "/dev/disk/by-partlabel/$label"
  done

  # *** setup RW areas ***

  systemd-tmpfiles --create --remove --boot --exclude-prefix=/dev
  systemd-tmpfiles --create /usr/comma/tmpfiles.conf

  # setup /var and /home overlays
  mkdir -p /var/log/
  chown root:syslog /var/log
  mount_fs tmpfs /var/log tmpfs rw,nosuid,nodev,size=128M,mode=755

  mkdir -p /rwtmp/home_work /rwtmp/home_upper
  chmod 755 /rwtmp/*
  mount_fs overlay /home overlay lowerdir=/usr/default/home,upperdir=/rwtmp/home_upper,workdir=/rwtmp/home_work

  # /data setup
  rm -rf /data/tmp/
  mkdir -p /data/etc /data/ssh /data/tmp /data/etc/netplan /data/etc/NetworkManager/system-connections
  touch /data/etc/timezone /data/etc/localtime
  chown comma: /data/ssh
  chown comma:comma /data/
  # These directories replaced the old /system/persist template on master.
  mkdir -p /data/persist/hlos_rfs/shared /data/persist/rfs/shared \
    /data/persist/rfs/msm/adsp /data/persist/rfs/msm/mpss
  [[ ! -d /data/media ]] || chown comma: /data/media

  # /cache
  mkdir -p /cache/debug
  chown comma:comma /cache /cache/debug
)

function init_qcom (
  # raise scaling_max so policy=performance can reach the BOOST top step
  echo 2649600 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
  echo 2649600 > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq

  # don't restart whole SoC on subsystem crash
  printf "%s\n" related | tee /sys/bus/msm_subsys/devices/subsys*/restart_level > /dev/null

  # setup firmware
  if ! await 10 test -s /firmware/image/adsp.mdt; then
    log_console "timed out waiting for /firmware/image/adsp.mdt"
  fi

  /usr/bin/irsc_util

  # boot audio + compute DSPs
  echo 1 > /sys/kernel/boot_adsp/boot
  echo 1 > /sys/kernel/boot_cdsp/boot

  # boot wifi
  echo 1 > /sys/kernel/boot_wlan/boot_wlan

  # ipa
  echo 1 > /dev/ipa
)

function init_power_burn (
  # blip power to ~10W to see if the PSU is stable
  chrt -i 0 timeout --kill-after=1 1 /usr/comma/power_burn_max 0.5 8

  # limit after burn
  echo 1689600 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
  echo 1689600 > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
)

function init_gpio (
  pins=(
    30  # HUB_RST_N
    49  # SOM_ST_IO
    134 # ST_BOOT0
    41  # PANDA_1V8_EN_N
    50  # LTE_RST_N
    116 # LTE_PWRKEY
    124 # ST_RST_N
    34  # GPS_PWR_EN
    33  # GPS_SAFEBOOT_N
    32  # GPS_RST_N
    52  # LTE_BOOT
    1264  # POWER ALERT
  )

  for p in "${pins[@]}"; do
    if [[ "$p" == 41 ]] && grep -q "comma tici" /sys/firmware/devicetree/base/model; then
      continue
    fi
    [[ -d /sys/class/gpio/gpio$p ]] || echo "$p" > /sys/class/gpio/export
    await test -d /sys/class/gpio/gpio$p
  done

  echo out > /sys/class/gpio/gpio30/direction
  echo 1 > /sys/class/gpio/gpio30/value

  # set permissions
  find -H /sys/class/gpio/export /sys/class/gpio/unexport /sys/class/gpio/gpio* \
    -maxdepth 1 -exec chown root:gpio {} + -exec chmod 770 {} +
)

function init_sound (
  await grep -qs "^ONLINE$" /proc/asound/card0/state
  echo "sound card online"

  await amixer -D hw:0 -q cset "name='SEC_MI2S_RX Audio Mixer MultiMedia1'" 1
  echo "mixer controls ready"

  if [[ "$(< /sys/firmware/devicetree/base/model)" == *mici* ]]; then
    amixer -D hw:0 -q cset "name='MultiMedia1 Mixer SEC_MI2S_TX'" 1
  else
    amixer -D hw:0 -q cset "name='MultiMedia1 Mixer TERT_MI2S_TX'" 1
    amixer -D hw:0 -q cset "name='TERT_MI2S_TX Channels'" Two
  fi
)

function init_screen_calibration (
  await mountpoint -q /persist
  /usr/comma/screen_calibration.py
)

function init_hostname (
  # set the device's hostname to "comma-<device_serial_number>"
  await test -r /proc/cmdline
  sysctl kernel.hostname="comma-$(sed -n 's/.*androidboot.serialno=\([^ ]*\).*/\1/p' /proc/cmdline)"
)

function init_debug (
  await mountpoint -q /cache
  sudo -u comma /usr/comma/debug.py
)

# each init function should:
# - start immediately in the background
# - manage its own dependencies
run_init init_permissions &
run_init init_filesystems &
run_init init_qcom &
run_init init_power_burn &
run_init init_gpio &
run_init init_sound &
run_init init_screen_calibration &
run_init init_hostname &
run_init init_debug &
wait

log_console "********** init done **********"
