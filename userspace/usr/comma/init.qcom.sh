#!/bin/bash

# don't restart whole SoC on subsystem crash
for i in {0..7}; do
  echo "related" | sudo tee /sys/bus/msm_subsys/devices/subsys${i}/restart_level
done

# use max freq to boot up quickly, then limit
echo 1689600 | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
echo 1689600 | sudo tee /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq

# boot wifi
echo 1 | sudo tee /sys/kernel/boot_wlan/boot_wlan
