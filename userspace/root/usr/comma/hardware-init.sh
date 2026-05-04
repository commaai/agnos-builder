#!/bin/bash

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

init_qcom &
init_gpio &
init_sound &
init_screen_calibration &
init_hostname &
init_debug &

wait
