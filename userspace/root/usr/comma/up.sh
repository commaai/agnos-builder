#!/bin/bash
# setup for the ultimate provisioning (UP) board. does nothing on other devices
grep -q "ultimate provisioning" /sys/firmware/devicetree/base/model || exit 0

# gpio.sh is for the tici. on a UP it never finishes, the TCAN driver owns some of its pins
systemctl mask --runtime --now gpio.service

# at 1.2 GHz the gold cores run ~17 C cooler under full CAN load, same CAN throughput.
# comma.sh sets its own limit on boot, so wait for that first
GOLD_MAX=/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
for i in {1..100}; do
  [ "$(cat $GOLD_MAX)" -eq 1689600 ] && break
  sleep 0.1
done
echo 1209600 > $GOLD_MAX
