#!/bin/bash
set -e

PATH=/usr/sbin:/usr/bin:/sbin:/bin

iface=wlan0
timeout=300

# mainline kernel: wlan0 only appears after the modem remoteproc chain
# (mainline-firmware -> rmtfs/tqftpserv/pd-mapper -> mss-start -> ath10k),
# typically 60-90s into boot. NM must not start before the fake udev entry
# below exists, or it pins wlan0 unmanaged (platform-init) until restarted.
if [[ -d /sys/class/remoteproc ]]; then
  timeout=3000
fi

for ((i = 0; i < timeout; i++)); do
  [[ -r "/sys/class/net/$iface/ifindex" ]] && break
  sleep 0.1
done

if [[ ! -r "/sys/class/net/$iface/ifindex" ]]; then
  echo "timed out waiting for $iface"
  exit 0
fi

ifindex=$(< "/sys/class/net/$iface/ifindex")
mkdir -p /run/udev/data
tmp=$(mktemp "/run/udev/data/n${ifindex}.XXXXXX")

{
  printf 'I:%s\n' "$(($(date +%s%N) / 1000))"
  printf 'E:NM_UNMANAGED=0\n'
  printf 'V:1\n'
} > "$tmp"

mv "$tmp" "/run/udev/data/n${ifindex}"
