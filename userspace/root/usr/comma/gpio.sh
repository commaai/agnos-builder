#!/bin/bash

source /usr/comma/gpio_base.sh

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

)

for p in ${pins[@]}; do
  echo $p

  # this is SSD_3v3 EN on tici
  if [ "$p" -eq 41 ] && grep -q "comma tici" /sys/firmware/devicetree/base/model; then
    echo "Skipping $p"
    continue
  fi

  pin=$(gpio_number "$p")
  if [ -d /sys/class/gpio/gpio$pin ]; then continue; fi
  echo $pin > /sys/class/gpio/export
  until [ -d /sys/class/gpio/gpio$pin ]
  do
    sleep .05
  done
done


HUB_RST_N=30
gpio $HUB_RST_N 1
