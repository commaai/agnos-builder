#!/bin/bash
# Boot the modem and hold it up for good. A kill while the modem's firmware is loading leaves it in
# a state that hangs the whole SoC on its next boot, so this is its own unit that nothing stops,
# restarts or OOM-kills. Wi-Fi restarts don't touch it.

# Restart a daemon if it exits, logging under its own name
daemon() {
  while true; do
    systemd-cat -t "$(basename "$1")" "$@"
    sleep 1
  done &
}

# the modem reads its EFS partitions through rmt_storage and /system/rfs through tftp_server
echo "modem: waiting for EFS partitions"
for p in modemst1 modemst2 fsc fsg; do
  until [ -e /dev/block/bootdevice/by-name/$p ]; do sleep 0.1; done
done
daemon /usr/sbin/rmt_storage
daemon /usr/sbin/tftp_server

# Opening /dev/subsys_modem boots the modem, and the kernel shuts it down
# when the last reference is released, so hold it open for good.
# https://github.com/commaai/agnos-kernel-sdm845/blob/8b0e4d289b246a5cc1b0484b25a3f9f8d4772544/drivers/soc/qcom/subsystem_restart.c#L1215-L1251
echo "modem: booting"
until exec 3< /dev/subsys_modem; do
  echo "modem: boot failed, retrying"
  sleep 1
done
echo "modem: booted"
wait
