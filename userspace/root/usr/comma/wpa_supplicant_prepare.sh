#!/bin/sh
# wpa_supplicant-wlan0.service: get the config ready before wpa_supplicant starts
conf=/data/etc/wpa_supplicant/wlan0.conf

# AGNOS's globals, plus the channels of the last networks so the first scan after boot is short
# (dhcpcd's 50-agnos hook saves them, one per line). Only a hint: anything but a channel is left out
{
  cat /etc/wpa_supplicant/wlan0-globals.conf
  freqs=$(grep -axE '[2-7][0-9]{3}' /data/etc/dhcpcd/wifi-freqs 2>/dev/null | head -n 4 | tr '\n' ' ')
  [ -z "$freqs" ] || echo "initial_freq_list=$freqs"
} > /run/wpa_supplicant-wlan0-globals.conf

# first start: an empty config, and NetworkManager's networks get imported once wpa_supplicant is up
# (wifi-migrate.service, temporary)
if [ ! -e "$conf" ]; then
  mkdir -p "${conf%/*}"
  touch "${conf%/*}/migrate-from-networkmanager"
  echo update_config=1 > "$conf"
fi

# A config wpa_supplicant can't read would keep Wi-Fi down for good (one a newer AGNOS wrote, after falling back to
# the other slot): set it aside and start with no networks. A dry run on an interface that doesn't exist reads the
# config, then stops at the driver
if wpa_supplicant -i agnos-check -D wired -c "$conf" 2>&1 | grep -q "Failed to read or parse configuration"; then
  mv "$conf" "$conf.unreadable"
  echo update_config=1 > "$conf"
fi

# Start with every saved network enabled. openpilot tries a new network alone, with the others disabled in RAM until
# it's done, and a save made meanwhile keeps that: drop the disabled=1 lines, which keeps those networks. Written
# like wpa_supplicant's own saves: synced, then renamed over the config
if grep -qxE '[[:space:]]+disabled=1' "$conf"; then
  grep -vxE '[[:space:]]+disabled=1' "$conf" > "$conf.tmp" && sync "$conf.tmp" && mv "$conf.tmp" "$conf" || rm -f "$conf.tmp"
fi
