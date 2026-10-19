#!/bin/bash
# Boot the Qualcomm subsystems and run their daemons. Wi-Fi runs on the
# modem subsystem, so it needs all of this.

# Restart a daemon if it exits, logging under its own name
daemon() {
  while true; do
    systemd-cat -t "$(basename "$1")" "$@"
    sleep 1
  done &
}

# IPC router security rules, before any QMI clients start
/usr/bin/irsc_util

# don't restart whole SoC on subsystem crash
for i in {0..7}; do
  echo related > /sys/bus/msm_subsys/devices/subsys${i}/restart_level
done

# raise scaling_max so policy=performance can reach the BOOST top step
echo 2649600 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
echo 2649600 > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq

# IPA firmware and compute DSP
echo 1 > /dev/ipa
echo 1 > /sys/kernel/boot_cdsp/boot

# the modem reads its EFS partitions through rmt_storage and /system/rfs through tftp_server
for p in modemst1 modemst2 fsc fsg; do
  until [ -e /dev/block/bootdevice/by-name/$p ]; do sleep 0.1; done
done
daemon /usr/sbin/rmt_storage
daemon /usr/sbin/tftp_server

# boot the modem subsystem; it stays up while init_mss holds /dev/subsys_modem open
daemon /usr/sbin/init_mss
daemon /usr/bin/pdmappersvc
daemon /usr/sbin/cnss_daemon -n

# boot wifi
echo 1 > /sys/kernel/boot_wlan/boot_wlan

wait
