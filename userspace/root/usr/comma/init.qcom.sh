#!/bin/bash

# centralized qualcomm init

# don't restart whole SoC on subsystem crash
for i in {0..7}; do
  echo "related" | sudo tee /sys/bus/msm_subsys/devices/subsys${i}/restart_level
done

# raise scaling_max so policy=performance can reach the BOOST top step
echo 2649600 | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
echo 2649600 | sudo tee /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq

# *** wifi ***
# boot wifi
echo 1 | sudo tee /sys/kernel/boot_wlan/boot_wlan
/usr/bin/irsc_util /etc/sec_config

# cdsp
echo 1 > /sys/kernel/boot_cdsp/boot
