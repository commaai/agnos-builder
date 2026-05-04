#!/bin/bash

# centralized qualcomm init
# *************************

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
echo 1 | sudo tee /sys/kernel/boot_wlan/boot_wlan
/usr/bin/irsc_util /etc/sec_config

# boot audio + compute DSPs
echo 1 > /sys/kernel/boot_adsp/boot
echo 1 > /sys/kernel/boot_cdsp/boot

# ipa
echo 1 > /dev/ipa
