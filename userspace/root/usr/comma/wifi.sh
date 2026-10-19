#!/bin/bash
# Bring up the Wi-Fi stack. The Wi-Fi firmware runs on the modem subsystem,
# so this boots the modem and runs the daemons it needs.
#
# Each step runs in its own background job, so a subsystem that hangs
# while booting doesn't block the others.

# Boot a subsystem in the background, logging when it's up
boot() {
  local name=$1 node=$2
  (
    echo "$name: booting"
    echo 1 > "$node" && echo "$name: booted" || echo "$name: boot failed"
  ) &
}

# Restart a daemon if it exits, logging under its own name
daemon() {
  while true; do
    systemd-cat -t "$(basename "$1")" "$@"
    sleep 1
  done &
}

# IPC router security rules. The daemons below are the only IPC router
# clients, and they block until this has run.
/usr/bin/irsc_util

boot ipa /dev/ipa
boot wlan /sys/kernel/boot_wlan/boot_wlan

# modem
(
  # the modem reads its EFS partitions through rmt_storage and /system/rfs through tftp_server
  echo "modem: waiting for EFS partitions"
  for p in modemst1 modemst2 fsc fsg; do
    until [ -e /dev/block/bootdevice/by-name/$p ]; do sleep 0.1; done
  done
  daemon /usr/sbin/rmt_storage
  daemon /usr/sbin/tftp_server

  # boots the modem; it stays up while init_mss holds /dev/subsys_modem open
  echo "modem: booting"
  daemon /usr/sbin/init_mss
  daemon /usr/bin/pdmappersvc
  daemon /usr/sbin/cnss_daemon -n
  wait
) &

wait
