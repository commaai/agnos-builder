#!/bin/bash

PATH=/usr/sbin:/usr/bin:/sbin:/bin

function log_init {
  local msg="comma-init: $*"

  echo "$msg"
  echo "$msg" > /dev/console
}

function run_init {
  local name="$1"
  local start_time end_time elapsed ret

  log_init "$name started"
  start_time="$EPOCHREALTIME"

  "$name"
  ret=$?

  end_time="$EPOCHREALTIME"
  elapsed="$(awk "BEGIN { printf \"%.1f\", $end_time - $start_time }")"
  log_init "$name finished after ${elapsed}s"

  return $ret
}

function wait_for_block {
  local device="$1"
  local i

  for ((i = 0; i < 150; i++)); do
    if [[ -b "$device" ]]; then
      return 0
    fi
    sleep 0.02
  done

  log_init "timed out waiting for $device"
  return 1
}

function mount_fs {
  local what="$1"
  local where="$2"
  local type="$3"
  local options="$4"

  if [[ "$what" == /dev/* ]] && ! wait_for_block "$what"; then
    failed=1
    return 1
  fi

  log_init "mounting $where"
  if mount --mkdir -t "$type" -o "$options" "$what" "$where"; then
    log_init "mounted $where"
    return 0
  fi

  log_init "failed mounting $where"
  failed=1
  return 1
}

function setup_filesystems {
  failed=0
  mount_fs /dev/sde9 /dsp ext4 ro
  mount_fs /dev/sde4 /firmware vfat ro
  mount_fs /dev/sda2 /persist squashfs ro,nosuid,nodev,noexec
  mount_fs /dev/sda10 /systemrw ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev
  mount_fs /dev/sda12 /data ext4 discard,noatime,nodiratime,nosuid,nodev
  mount_fs /dev/sda11 /cache ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid
  mount_fs tmpfs /var tmpfs rw,nosuid,nodev,size=128M,mode=755
  mount_fs tmpfs /tmp tmpfs rw,nosuid,nodev,size=150M,mode=1777
  mount_fs tmpfs /rwtmp tmpfs rw,nosuid,nodev,size=100M,mode=1777

  systemd-tmpfiles --create /usr/comma/tmpfiles.conf

  mkdir -p /var/log/
  chown root:syslog /var/log
  mount -t tmpfs -o rw,nosuid,nodev,size=128M,mode=755 tmpfs /var/log

  mkdir -p /rwtmp/home_work
  mkdir -p /rwtmp/home_upper
  chmod 755 /rwtmp/*
  mount -t overlay overlay -o lowerdir=/usr/default/home,upperdir=/rwtmp/home_upper,workdir=/rwtmp/home_work /home

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
    log_init "mounts failed"
    return 1
  fi
}

function init_qcom {
  # don't restart whole SoC on subsystem crash
  for i in {0..7}; do
    echo "related" | sudo tee /sys/bus/msm_subsys/devices/subsys${i}/restart_level
  done

  # raise scaling_max so policy=performance can reach the BOOST top step
  echo 2649600 | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
  echo 2649600 | sudo tee /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq

  # setup firmware
  echo -n "/firmware/image" > /sys/module/firmware_class/parameters/path
  count=0
  while [ ! -s /firmware/image/adsp.mdt ]; do
    # wait 10s for /firmware mounted
    count=$(( $count + 1 ))
    if [ $count -ge 100 ]; then
      echo "[ERROR] /firmware not mounted"
    fi
    sleep 0.1
  done

  # boot wifi
  echo 1 > /sys/kernel/boot_wlan/boot_wlan
  /usr/bin/irsc_util /etc/sec_config

  # boot audio + compute DSPs
  echo 1 > /sys/kernel/boot_adsp/boot
  echo 1 > /sys/kernel/boot_cdsp/boot

  # ipa
  echo 1 > /dev/ipa

  echo "qcom init done"
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
    echo $p

    echo $p > /sys/class/gpio/export
    until [ -d /sys/class/gpio/gpio$p ]; do
      sleep .05
    done
  done
}

function init_sound {
  echo "waiting for sound card to come online"
  while [ ! -d /proc/asound/sdm845tavilsndc ] || [ "$(cat /proc/asound/card0/state 2> /dev/null)" != "ONLINE" ] ; do
    sleep 0.01
  done
  echo "sound card online"

  while ! /usr/comma/sound/tinymix controls | grep -q "SEC_MI2S_RX Audio Mixer MultiMedia1"; do
    sleep 0.01
  done
  echo "tinymix controls ready"

  /usr/comma/sound/tinymix set "SEC_MI2S_RX Audio Mixer MultiMedia1" 1
  if grep -q mici /sys/firmware/devicetree/base/model; then
    /usr/comma/sound/tinymix set "MultiMedia1 Mixer SEC_MI2S_TX" 1
  else
    /usr/comma/sound/tinymix set "MultiMedia1 Mixer TERT_MI2S_TX" 1
    /usr/comma/sound/tinymix set "TERT_MI2S_TX Channels" Two
  fi
}

function init_screen_calibration {
  while ! mountpoint -q /persist; do
    sleep 0.1
  done

  /usr/comma/screen_calibration.py
}

function init_hostname {
  local serial
  while [ ! -r /proc/cmdline ]; do
    sleep 0.1
  done

  serial="$(cat /proc/cmdline | sed -e 's/^.*androidboot.serialno=//' -e 's/ .*$//')"
  echo "serial: '$serial'"
  sysctl kernel.hostname="comma-$serial"
}

function init_debug {
  while ! mountpoint -q /cache; do
    sleep 0.1
  done

  sudo -u comma /usr/comma/debug.py
}

run_init setup_filesystems

run_init init_qcom &
run_init init_gpio &
run_init init_sound &
run_init init_screen_calibration &
run_init init_hostname &
run_init init_debug &

wait
