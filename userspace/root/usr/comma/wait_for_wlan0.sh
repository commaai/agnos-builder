#!/bin/sh
# wpa_supplicant-wlan0 and dhcpcd-wlan0: run the daemon ("$@") once wlan0 exists. wlan0 only appears once the Wi-Fi
# firmware has booted (wifi.service); waiting here instead of in ExecStartPre lets the units count as started at once,
# so nothing waits on the firmware with them. Give up after 30s, and the unit tries again
timeout 30 sh -c 'until [ -e /sys/class/net/wlan0 ]; do sleep 0.05; done' || exit 1
exec "$@"
