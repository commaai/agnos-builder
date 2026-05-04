#!/bin/bash

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

init_gpio &
init_sound &
init_screen_calibration &

wait
