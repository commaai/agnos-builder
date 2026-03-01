#!/bin/bash

function gpio {
  echo "out" > /sys/class/gpio/gpio$1/direction
  echo $2 > /sys/class/gpio/gpio$1/value
}

pins=(
# 27  # SW_3V3_EN
# 25  # SW_5V_EN
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

for p in ${pins[@]}; do
  echo $p

  # this is SSD_3v3 EN on tici
  if [ "$p" -eq 41 ] && grep -q "comma tici" /sys/firmware/devicetree/base/model; then
    echo "Skipping $p"
    continue
  fi

  echo $p > /sys/class/gpio/export
  until [ -d /sys/class/gpio/gpio$p ]
  do
    sleep .05
  done
  # eudev doesn't apply GROUP/MODE from udev rules to sysfs GPIO files
  # like systemd-udevd does, so set permissions manually after export
  chown root:gpio /sys/class/gpio/gpio$p/direction /sys/class/gpio/gpio$p/value 2>/dev/null
  chmod 660 /sys/class/gpio/gpio$p/direction /sys/class/gpio/gpio$p/value 2>/dev/null
done


HUB_RST_N=30
gpio $HUB_RST_N 1
