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
  chmod 0666 /dev/input/event2

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

function init_video (
  await 3 test -e /sys/class/video4linux/v4l-subdev11/uevent

  mkdir -p /dev/v4l/by-path
  ln -sfn ../../video0 /dev/v4l/by-path/platform-soc:qcom_cam-req-mgr-video-index0
  ln -sfn ../../video1 /dev/v4l/by-path/platform-cam_sync-video-index0

  for path in /dev/video0 /dev/video1 /dev/v4l-subdev*; do
    [[ -c "$path" ]] || continue
    chgrp video "$path"
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
  mount_fs /dev/sda2 /persist squashfs ro,nosuid,nodev,noexec &
  mount_fs /dev/sda10 /systemrw ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev &
  mount_fs /dev/sda12 /data ext4 discard,noatime,nodiratime,nosuid,nodev &
  mount_fs /dev/sda11 /cache ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid &
  mount_fs tmpfs /var tmpfs rw,nosuid,nodev,size=128M,mode=755 &
  mount_fs tmpfs /tmp tmpfs rw,nosuid,nodev,size=150M,mode=1777 &
  mount_fs tmpfs /rwtmp tmpfs rw,nosuid,nodev,size=100M,mode=1777 &
  wait

  for path in /dev/sd[a-f]*; do
    [[ -b "$path" ]] || continue
    chgrp disk "$path"
    chmod 0660 "$path"
  done

  # rmt_storage and qseecomd are the only users of /dev/block/bootdevice/by-name.
  mkdir -p /dev/block/bootdevice/by-name
  ln -sf /dev/sda1 /dev/block/bootdevice/by-name/ssd
  ln -sf /dev/sdf2 /dev/block/bootdevice/by-name/modemst1
  ln -sf /dev/sdf3 /dev/block/bootdevice/by-name/modemst2
  ln -sf /dev/sdf4 /dev/block/bootdevice/by-name/fsg
  ln -sf /dev/sdf5 /dev/block/bootdevice/by-name/fsc

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
  if [[ ! -d /data/persist ]]; then
    cp -r /system/persist /data
  fi

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

  # boot audio + compute DSPs
  echo 1 > /sys/kernel/boot_adsp/boot
  echo 1 > /sys/kernel/boot_cdsp/boot

  # boot wifi
  echo 1 > /sys/kernel/boot_wlan/boot_wlan
  /usr/bin/irsc_util /etc/sec_config

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
    echo "$p" > /sys/class/gpio/export
  done

  # set permissions
  find -H /sys/class/gpio/export /sys/class/gpio/unexport /sys/class/gpio/gpio* \
    -maxdepth 1 -exec chown root:gpio {} + -exec chmod 770 {} +
)

function init_sound (
  await grep -qs "^ONLINE$" /proc/asound/card0/state
  echo "sound card online"

  find /dev/snd -maxdepth 1 -type c -exec chgrp audio {} + -exec chmod 0660 {} +

  await /usr/comma/sound/tinymix set "SEC_MI2S_RX Audio Mixer MultiMedia1" 1
  echo "tinymix controls ready"

  if [[ "$(< /sys/firmware/devicetree/base/model)" == *mici* ]]; then
    /usr/comma/sound/tinymix set "MultiMedia1 Mixer SEC_MI2S_TX" 1
  else
    /usr/comma/sound/tinymix set "MultiMedia1 Mixer TERT_MI2S_TX" 1
    /usr/comma/sound/tinymix set "TERT_MI2S_TX Channels" Two
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
run_init init_video &
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
