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
  log_console "$name finished after ${elapsed}s"

  return $ret
}

function init_filesystems {
  local failed=0
  local pids=()
  local pid

  function wait_for_block {
    local device="$1"
    local i

    for ((i = 0; i < 150; i++)); do
      if [[ -b "$device" ]]; then
        return 0
      fi
      sleep 0.02
    done

    log_console "timed out waiting for $device"
    return 1
  }

  function mount_fs {
    local what="$1"
    local where="$2"
    local type="$3"
    local options="$4"

    if mountpoint -q "$where"; then
      log_console "$where already mounted"
      return 0
    fi

    if [[ "$what" == /dev/* ]] && ! wait_for_block "$what"; then
      failed=1
      return 1
    fi

    log_console "mounting $where"
    if mount --mkdir -t "$type" -o "$options" "$what" "$where"; then
      log_console "mounted $where"
      return 0
    fi

    log_console "failed mounting $where"
    failed=1
    return 1
  }

  function mount_fs_bg {
    mount_fs "$@" &
    pids+=("$!")
  }

  mount_fs_bg /dev/sde9 /dsp ext4 ro
  mount_fs_bg /dev/sde4 /firmware vfat ro
  mount_fs_bg /dev/sda2 /persist squashfs ro,nosuid,nodev,noexec
  mount_fs_bg /dev/sda10 /systemrw ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev
  mount_fs_bg /dev/sda12 /data ext4 discard,noatime,nodiratime,nosuid,nodev
  mount_fs_bg /dev/sda11 /cache ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid
  mount_fs_bg tmpfs /var tmpfs rw,nosuid,nodev,size=128M,mode=755
  mount_fs_bg tmpfs /tmp tmpfs rw,nosuid,nodev,size=150M,mode=1777
  mount_fs_bg tmpfs /rwtmp tmpfs rw,nosuid,nodev,size=100M,mode=1777

  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done

  unset -f mount_fs_bg mount_fs wait_for_block

  systemd-tmpfiles --create /usr/comma/tmpfiles.conf

  mkdir -p /var/log/
  chown root:syslog /var/log
  if ! mountpoint -q /var/log; then
    if ! mount -t tmpfs -o rw,nosuid,nodev,size=128M,mode=755 tmpfs /var/log; then
      log_console "failed mounting /var/log"
      failed=1
    fi
  fi

  mkdir -p /rwtmp/home_work
  mkdir -p /rwtmp/home_upper
  chmod 755 /rwtmp/*
  if ! mountpoint -q /home; then
    if ! mount -t overlay overlay -o lowerdir=/usr/default/home,upperdir=/rwtmp/home_upper,workdir=/rwtmp/home_work /home; then
      log_console "failed mounting /home"
      failed=1
    fi
  fi

  mkdir -p /data/etc
  touch /data/etc/timezone
  touch /data/etc/localtime
  mkdir -p /data/etc/netplan
  mkdir -p /data/etc/NetworkManager/system-connections

  chown -R comma:comma /cache/

  mkdir -p /data/ssh
  chown comma: /data/ssh

  rm -rf /data/tmp/
  mkdir -p /data/tmp/

  if [[ ! -d /data/persist ]]; then
    sudo cp -r /system/persist /data
  fi

  if [[ "$failed" -ne 0 ]]; then
    log_console "mounts failed"
    return 1
  fi
}

function init_qcom {
  # don't restart whole SoC on subsystem crash
  for i in {0..7}; do
    echo "related" > /sys/bus/msm_subsys/devices/subsys${i}/restart_level
  done

  # raise scaling_max so policy=performance can reach the BOOST top step
  echo 2649600 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
  echo 2649600 > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq

  # setup firmware
  echo -n "/firmware/image" > /sys/module/firmware_class/parameters/path
  count=0
  while [ ! -s /firmware/image/adsp.mdt ]; do
    # wait 10s for /firmware mounted
    count=$(( $count + 1 ))
    if [ $count -ge 1000 ]; then
      echo "[ERROR] /firmware not mounted"
    fi
    sleep 0.01
  done

  # boot audio + compute DSPs
  echo 1 > /sys/kernel/boot_adsp/boot
  echo 1 > /sys/kernel/boot_cdsp/boot

  # boot wifi
  echo 1 > /sys/kernel/boot_wlan/boot_wlan
  /usr/bin/irsc_util /etc/sec_config

  # ipa
  echo 1 > /dev/ipa
}

function init_gpio {
  local pins=(
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

  echo "initializing gpio"

  for p in ${pins[@]}; do
    if [[ ! -d /sys/class/gpio/gpio$p ]]; then
      echo $p > /sys/class/gpio/export
    fi
    until [ -d /sys/class/gpio/gpio$p ]; do
      sleep .05
    done
  done
}

function init_sound {
  local state

  echo "waiting for sound card to come online"
  while true; do
    if [[ -d /proc/asound/sdm845tavilsndc && -r /proc/asound/card0/state ]]; then
      read -r state < /proc/asound/card0/state
      [[ "$state" == "ONLINE" ]] && break
    fi
    sleep 0.01
  done
  echo "sound card online"

  while ! /usr/comma/sound/tinymix set "SEC_MI2S_RX Audio Mixer MultiMedia1" 1; do
    sleep 0.01
  done
  echo "tinymix controls ready"

  if [[ "$(< /sys/firmware/devicetree/base/model)" == *mici* ]]; then
    /usr/comma/sound/tinymix set "MultiMedia1 Mixer SEC_MI2S_TX" 1
  else
    /usr/comma/sound/tinymix set "MultiMedia1 Mixer TERT_MI2S_TX" 1
    /usr/comma/sound/tinymix set "TERT_MI2S_TX Channels" Two
  fi
}

function init_screen_calibration {
  while ! mountpoint -q /persist; do
    sleep 0.01
  done

  /usr/comma/screen_calibration.py
}

function init_hostname {
  local serial
  while [ ! -r /proc/cmdline ]; do
    sleep 0.01
  done

  read -r cmdline < /proc/cmdline
  serial="${cmdline#*androidboot.serialno=}"
  serial="${serial%% *}"
  echo "serial: '$serial'"
  sysctl kernel.hostname="comma-$serial"
}

function init_debug {
  while ! mountpoint -q /cache; do
    sleep 0.01
  done

  sudo -u comma /usr/comma/debug.py
}

run_init init_filesystems &
run_init init_qcom &
run_init init_gpio &
run_init init_sound &
run_init init_screen_calibration &
run_init init_hostname &
run_init init_debug &

wait

log_console "********** init done **********"
