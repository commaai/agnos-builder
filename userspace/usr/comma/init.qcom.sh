#!/bin/bash

# don't restart whole SoC on subsystem crash
for i in {0..7}; do
  echo "related" | sudo tee /sys/bus/msm_subsys/devices/subsys${i}/restart_level
done

# boot wifi
echo 1 | sudo tee /sys/kernel/boot_wlan/boot_wlan
