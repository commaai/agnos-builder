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
  echo $p > /sys/class/gpio/export
  until [ -d /sys/class/gpio/gpio$p ]
  do
    sleep .05
  done
done


HUB_RST_N=30
gpio $HUB_RST_N 1
