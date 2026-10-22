#!/bin/bash
# setup for the ultimate provisioning (UP) board

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

# the USB7002 hub leaves reset at power-on, before the host's SuperSpeed port is up, and on about
# half the boots only its USB 2.0 half enumerates, so there's no eth0. reset the hub until eth0 shows up
HUB_RST=/sys/class/gpio/gpio134
[ -d $HUB_RST ] || echo 134 > /sys/class/gpio/export
for i in {1..5}; do
  for j in {1..100}; do
    [ -e /sys/class/net/eth0 ] && exit 0
    sleep 0.1
  done
  echo "no eth0, resetting the USB hub"
  echo high > $HUB_RST/direction
  sleep 0.2
  echo 0 > $HUB_RST/value
done
