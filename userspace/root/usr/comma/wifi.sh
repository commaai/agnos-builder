#!/bin/bash
# Bring up the Wi-Fi stack. The Wi-Fi firmware runs on the modem subsystem,
# which subsys-modem.service boots, so this runs the daemons it needs.
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

boot ipa /dev/ipa
boot wlan /sys/kernel/boot_wlan/boot_wlan

daemon /usr/bin/pdmappersvc
daemon /usr/sbin/cnss_daemon -n

wait
